defmodule HalC2.NativeSubagentSettlePropTest do
  @moduledoc """
  A state machine over a thread whose provider starts subagents of its own
  (`HalC2.Orchestration.NativeSubagent`), each working in a thread of its own that has
  no run, where a subagent may start subagents in turn, with tool calls opening and
  ending in those threads, subagents ending (`NativeSubagent.finish/4`) and being
  resumed (`NativeSubagent.resume/3`), and the MC settling the thread at a restart
  (`Recovery.settle/2`):

  - the settle ends every subagent still running under the thread, however deep, and
    every tool call still running in their threads, which no sidebar row shows active;
  - it leaves alone what had ended, and the threads of subagents that had ended, which
    are not its to settle;
  - a subagent that ends ends the tool calls still running in its thread, and plugins
    that hear turns hear each of them once, ended, as its parent turn's: a call cut
    short is still a use; the provider's own late report of a call's end
    (`NativeSubagent.item/5`) is heard only for a call still running;
  - a subagent resumed keeps the spans it worked before, in order and apart, so the
    turns between them are none of its (`HalC2.Plugins.Host.history/3`).
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.{NativeSubagent, Recovery}
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
          HalC2.Shell,
          {Registry, keys: :unique, name: HalC2.Plugins.Hooks}
        ])

        # This process hears turns as a plugin's feed would.
        {:ok, _} =
          Registry.register(HalC2.Plugins.Hooks, {:observe, "listener"}, %{
            id: "listener",
            dropped: :counters.new(1, [])
          })

        {history, state, result} = run_commands(__MODULE__, cmds)
        # Registering linked this process to the registry, which must not end it.
        Registry.unregister(HalC2.Plugins.Hooks, {:observe, "listener"})
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # subagents: n -> {the thread it runs under, its status}; items: tool call id ->
  # {thread, status}; rows: n -> {the thread showing subagent n's row, its status}. A
  # subagent's own thread is "child-n".
  def initial_state, do: %{subagents: %{}, items: %{}, rows: %{}}

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
            {1, {:call, __MODULE__, :finish, [oneof(Map.keys(state.subagents))]}},
            {1, {:call, __MODULE__, :resume, [oneof(Map.keys(state.subagents))]}}
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

  def precondition(state, {:call, _, :resume, [n]}),
    do: match?({_, status} when status != "running", state.subagents[n])

  def precondition(state, {:call, _, :end_tool, [id]}), do: Map.has_key?(state.items, id)
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :spawn, [n, under]}),
    do: %{
      state
      | subagents: Map.put(state.subagents, n, {under, "running"}),
        rows: Map.put(state.rows, n, {under, "running"})
    }

  def next_state(state, _result, {:call, _, :tool, [n, i]}),
    do: put_in(state.items[item(i)], {child(n), "running"})

  def next_state(state, _result, {:call, _, :finish, [n]}) do
    state
    |> update_in([:subagents, n], fn {under, _} -> {under, "completed"} end)
    |> update_in([:rows, n], fn {under, _} -> {under, "completed"} end)
    |> Map.update!(:items, &settle(&1, [child(n)], "completed"))
    |> Map.update!(:rows, &settle(&1, [child(n)], "completed"))
  end

  def next_state(state, _result, {:call, _, :resume, [n]}) do
    state
    |> update_in([:subagents, n], fn {under, _} -> {under, "running"} end)
    |> update_in([:rows, n], fn {under, _} -> {under, "running"} end)
  end

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
      items: settle(state.items, threads(ended), "interrupted"),
      rows: settle(state.rows, [@thread | threads(ended)], "interrupted")
    }
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :restart, _}, seen) do
    after_restart = next_state(state, nil, {:call, __MODULE__, :restart, []})

    seen ==
      %{
        subagents: Map.new(after_restart.subagents, fn {n, {_, status}} -> {n, status} end),
        items: Map.new(after_restart.items, fn {id, {_, status}} -> {id, status} end),
        rows: Map.new(after_restart.rows, fn {n, {_, status}} -> {n, status} end)
      }
  end

  # Heard once each, ended, as the parent turn's: the calls its thread had running, and
  # the rows of the subagents it had started still shown running there.
  def postcondition(state, {:call, _, :finish, [n]}, heard) do
    {under, _} = state.subagents[n]

    running =
      for({id, {thread, "running"}} <- state.items, thread == child(n), do: id) ++
        for {m, {thread, "running"}} <- state.rows, thread == child(n), do: row(m)

    Enum.sort(Enum.map(heard, & &1["itemId"])) == Enum.sort(running) and
      Enum.all?(heard, fn item ->
        match?(
          %{
            "type" => "turn.item",
            "status" => "completed",
            "threadId" => ^under,
            "runId" => "r1",
            "subagent" => true
          },
          item
        )
      end)
  end

  # The spans it worked, each from its start or resume to its end, in order and
  # apart, the last ended by the time it was resumed.
  def postcondition(_state, {:call, _, :resume, _}, {before, record}) do
    spans = record["workedSpans"] || []
    ends = Enum.flat_map(spans, &[&1["from"], &1["to"]]) ++ [record["resumedAt"]]

    added =
      if is_binary(before["completedAt"]),
        do: [
          %{"from" => before["resumedAt"] || before["startedAt"], "to" => before["completedAt"]}
        ],
        else: []

    spans == (before["workedSpans"] || []) ++ added and
      (spans == [] or (Enum.all?(ends, &is_binary/1) and ends == Enum.sort(ends)))
  end

  # The provider reports the call's end: heard once, as it ends, and not for a call that
  # had ended (its subagent's end cut it short).
  def postcondition(state, {:call, _, :end_tool, [id]}, heard) do
    case state.items[id] do
      {_, "running"} -> match?([%{"itemId" => ^id, "status" => "completed"}], heard)
      _ -> heard == []
    end
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

  # What still runs in `threads` ends as `status`.
  defp settle(entries, threads, status) do
    Map.new(entries, fn
      {key, {thread, "running"}} ->
        {key, {thread, if(thread in threads, do: status, else: "running")}}

      other ->
        other
    end)
  end

  # --- commands -------------------------------------------------------------------

  # The provider of `under` starts subagent `n`, which works in its own thread.
  def spawn(n, under) do
    id = "subagent-#{n}"

    at = HalC2.Orchestration.Entities.now()

    commit(under, [
      {"subagent", id,
       %{
         "id" => id,
         "threadId" => under,
         "runId" => "r1",
         "origin" => "provider_native",
         "status" => "running",
         "childThreadId" => child(n),
         "nativeTaskRef" => %{"nativeId" => "native-#{n}"},
         "startedAt" => at,
         "completedAt" => nil
       }},
      {"node", id, %{"id" => id, "status" => "running"}},
      {"turn-item", row(n),
       %{
         "id" => row(n),
         "type" => "subagent",
         "status" => "running",
         "ordinal" => 1000 + n
       }}
    ])
  end

  # Subagent `n` calls a tool, which shows in its thread.
  def tool(n, i),
    do:
      commit(child(n), [
        {"turn-item", item(i),
         %{"id" => item(i), "type" => "command_execution", "status" => "running", "ordinal" => i}}
      ])

  # Subagent `n` ends, as the provider's runtime ends it; returns what plugins heard.
  def finish(n) do
    NativeSubagent.finish(handle(n), "completed", "Done")
    heard([])
  end

  # The handle the provider's runtime holds for subagent `n`.
  defp handle(n) do
    {under, _} = owner(n)

    %{
      id: "subagent-#{n}",
      item: row(n),
      thread: under,
      run: "r1",
      child: child(n),
      root: "node:subagent-root:codex:native-#{n}",
      native: "native-#{n}",
      driver: "codex",
      sender: under,
      text: ""
    }
  end

  defp heard(acc) do
    receive do
      {:observe, event} -> heard([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The provider resumes subagent `n` in a later turn; its record before and after.
  def resume(n) do
    {under, _} = owner(n)
    id = "subagent-#{n}"
    before = StreamState.get(stream(under), "subagent")[id]
    ids = %{thread: under, run: "r2", root_node: "node:root:r2", provider_thread: nil}
    NativeSubagent.resume(ids, before, "Again")
    {before, StreamState.get(stream(under), "subagent")[id]}
  end

  # The provider reports that tool call `id` ended, whenever it does: Codex keeps a
  # finished subagent and still routes its calls' ends to it. Returns what plugins heard.
  def end_tool("turn-item:codex:" <> native = id) do
    "child-" <> n = Enum.find(streams(), &StreamState.get(stream(&1), "turn-item")[id])

    NativeSubagent.item(
      handle(String.to_integer(n)),
      native,
      "command_execution",
      "completed",
      %{}
    )

    heard([])
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
          %{"id" => "turn-item:codex:item-" <> _ = id, "status" => status} <-
            StreamState.list(state, "turn-item"),
          into: %{},
          do: {id, status}
        ),
      rows:
        for(
          state <- states,
          %{"id" => "turn-item:subagent:subagent-" <> n, "status" => status} <-
            StreamState.list(state, "turn-item"),
          into: %{},
          do: {String.to_integer(n), status}
        )
    }
  end

  # --- helpers --------------------------------------------------------------------

  defp child(n), do: "child-#{n}"
  defp item(i), do: "turn-item:codex:item-#{i}"
  defp row(n), do: "turn-item:subagent:subagent-#{n}"

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
