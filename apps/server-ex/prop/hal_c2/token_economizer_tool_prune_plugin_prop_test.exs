for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge tool_prune_evidence token_economizer),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerToolPrunePluginPropTest do
  @moduledoc """
  A state machine model of TokenEconomizer's tool pruning in its process
  (`HalC2Plugins.TokenEconomizer`): the Claude turns of two threads of one project,
  each written to the thread's stream as the MC writes it and heard through the feed,
  which may drop a tool use and say so with its next event. A use may be a subagent's,
  heard as its parent turn's but kept in the child's thread: the parent's history
  shows only that a subagent worked in the turn. The plugin stops and
  starts again (missing whatever ran meanwhile), its history reads fail while it has
  no grant, a thread rolls turns back and is forked, the mode moves between off,
  propose and auto, and the person applies and restores tools. After every step:

  - every use the plugin must know of is in its evidence's used list: one it heard,
    and, once it read a thread's history after starting, any of the thread's turns
    that ended and are still in it, the uses dropped since it started aside (those
    it reads back as their conversation folds, which the model does not follow), and
    the subagents' (which no history read shows);
  - it uses no tool no turn used;
  - no tool it must know is used is proposed, or turned off for a new conversation;
  - no tool's streak counts more ended turns than those that did not use it, so a
    use it missed and could not read back is no evidence the tool went unused;
  - it counts no turn twice, whatever a rollback or a fork did to the history;
  - what it holds is what its file keeps, so a restart loses nothing.

  `prop/hal_c2/token_economizer_tool_prune_prop_test.exs` runs the evidence's own
  counters; `proof/hal_c2/token_economizer_tool_prune_proof_test.exs` explores the
  design over every interleaving, up to its bounds.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer
  alias HalC2Plugins.TokenEconomizer.ToolPrune.Evidence, as: Prune

  @id "token-economizer"
  @provider "claudeAgent"
  @project_id "p"
  @project {@project_id, @provider}
  @tools ~w(CronCreate Workflow CronList ScheduleWakeup)
  @threads ~w(a b)
  # Well under the 50 turns a history read returns.
  @max_runs 30

  property "tool pruning knows every use it heard or read back, over restarts, missed uses, failed reads, rollbacks and forks",
    numtests: HalC2.Prop.numtests(300) do
    forall cmds <- more_commands(4, commands(__MODULE__)) do
      open_case()
      {history, state, result} = run_commands(__MODULE__, cmds)
      close_case()

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  defp open_case do
    home = HalC2.Prop.scratch_home("token-economizer-prune")
    File.write!(Path.join(home, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)

    HalC2.Prop.start_services([
      HalC2.Settings,
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams
    ])

    grant(true)
    Process.put(:mode, "propose")
    start_plugin()
  end

  defp close_case do
    stop_plugin()
    Process.delete(:mode)
    Process.delete(:drop)
    HalC2.Prop.stop_services()
    Application.delete_env(:hal_c2, :settings_check_ms)
  end

  # Thresholds low enough for one unused conversation to propose a tool, and no
  # quiet to wait for under auto.
  defp settings(mode),
    do: %{
      "loopGuard" => "off",
      "toolPrune" => mode,
      "toolPruneEvidence" => 1,
      "toolPruneMinSessions" => 1,
      "toolPruneSessions" => 2,
      "toolPruneQuietMinutes" => 0
    }

  defp start_plugin do
    {:ok, plugin} = TokenEconomizer.init(settings(Process.get(:mode)))
    Process.put(:plugin, plugin)
  end

  defp stop_plugin do
    case Process.delete(:plugin) do
      nil ->
        :ok

      plugin ->
        ref = Process.monitor(plugin.sup)
        Process.unlink(plugin.sup)
        Process.exit(plugin.sup, :shutdown)
        receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
        flush()
    end
  end

  # The quiet timer's ticks, sent to this process; the case ticks by command.
  defp flush do
    receive do
      {:toolprune_tick, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp grant(on) do
    {settings, version} = HalC2.Settings.get()

    plugins = %{
      @id => %{
        "enabled" => true,
        "granted" => if(on, do: ["turns:observe"], else: []),
        "settings" => %{}
      }
    }

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
  end

  # --- the model --------------------------------------------------------------------------

  # `threads`: thread => %{runs: [%{id, ordinal, status, tools}], base}, oldest run
  # first, its own runs alone (`base` is the last ordinal a fork copied in); a run's
  # tools are `{tool, period, via}`, the plugin's run (`period`) in which the feed
  # dropped the use, or nil, and whose use it was (`:own`, or a `:subagent`'s). `open`: thread => its run under way. `heard`: the threads whose
  # conversation the plugin holds, having heard a turn of it start since it started;
  # `read`: those whose history it read since. `owed`: the uses it must know of.
  def initial_state,
    do: %{
      up: true,
      period: 0,
      history: true,
      mode: "propose",
      threads: %{},
      open: %{},
      heard: [],
      read: [],
      owed: [],
      used: [],
      runs: 0,
      forked: false
    }

  def command(s) do
    threads = @threads ++ if(s.forked, do: ["f"], else: [])
    open = Map.keys(s.open)
    idle = threads -- open

    rollbackable =
      for {t, %{runs: runs}} <- s.threads, t not in open, ended(runs) != [], do: t

    forkable =
      if s.forked,
        do: [],
        else: for({t, _} <- s.threads, t in @threads, t not in open, do: t)

    tools = oneof([nil, elements(Enum.map(@tools, &[&1]))])

    [
      idle != [] and s.runs < @max_runs and {6, start_call(s, idle)},
      open != [] and {8, use_call(s, open)},
      open != [] and {5, finish_call(s, open)},
      {2, {:call, __MODULE__, :tick, []}},
      {1, {:call, __MODULE__, :mode, [elements(~w(off propose auto))]}},
      {2, {:call, __MODULE__, :apply_tools, [tools]}},
      {1, {:call, __MODULE__, :restore, [tools]}},
      s.up and {1, {:call, __MODULE__, :down, []}},
      not s.up and {3, {:call, __MODULE__, :up, []}},
      {1, {:call, __MODULE__, :history, [not s.history]}},
      rollbackable != [] and {1, rollback_call(s, rollbackable)},
      forkable != [] and {1, fork_call(s, forkable)}
    ]
    |> Enum.filter(& &1)
    |> frequency()
  end

  defp start_call(s, idle) do
    let [thread <- elements(idle), new? <- boolean()] do
      first? = not Map.has_key?(s.threads, thread)
      run = "r#{s.runs + 1}"
      {:call, __MODULE__, :start, [thread, run, next_ordinal(s, thread), new? or first?, first?]}
    end
  end

  defp use_call(s, open) do
    let [
      thread <- elements(open),
      tool <- elements(@tools),
      drop <- frequency([{3, false}, {1, true}]),
      via <- frequency([{3, :own}, {1, :subagent}])
    ] do
      run = s.open[thread]
      n = length(current(s, thread).tools) + 1
      {:call, __MODULE__, :use, [thread, run, n, tool, drop, via]}
    end
  end

  defp finish_call(s, open) do
    let thread <- elements(open) do
      {:call, __MODULE__, :finish, [thread, s.open[thread], current(s, thread).ordinal]}
    end
  end

  # A rollback takes the thread's latest turns out of its history.
  defp rollback_call(s, threads) do
    let [thread <- elements(threads), k <- integer(1, 2)] do
      runs = s.threads[thread].runs |> ended() |> Enum.take(-k)
      {:call, __MODULE__, :rollback, [thread, Enum.map(runs, &{&1.id, &1.ordinal})]}
    end
  end

  # A fork copies the source's history, under the source's provider thread.
  defp fork_call(s, threads) do
    let source <- elements(threads) do
      copies =
        for run <- ended(s.threads[source].runs),
            do: {run.id, run.ordinal, Enum.map(run.tools, &{elem(&1, 0), elem(&1, 2)})}

      {:call, __MODULE__, :fork, [source, copies]}
    end
  end

  def precondition(s, {:call, _, :start, [thread | _]}),
    do: not Map.has_key?(s.open, thread) and s.runs < @max_runs

  def precondition(s, {:call, _, :use, [thread, run | _]}), do: s.open[thread] == run
  def precondition(s, {:call, _, :finish, [thread, run, _]}), do: s.open[thread] == run
  def precondition(s, {:call, _, :down, _}), do: s.up
  def precondition(s, {:call, _, :up, _}), do: not s.up

  def precondition(s, {:call, _, :rollback, [thread, runs]}) do
    not Map.has_key?(s.open, thread) and runs != [] and
      Enum.all?(runs, fn {id, _} ->
        id in Enum.map(ended(s.threads[thread][:runs] || []), & &1.id)
      end)
  end

  def precondition(s, {:call, _, :fork, [source, _]}),
    do: not s.forked and not Map.has_key?(s.open, source)

  def precondition(_s, _call), do: true

  def next_state(s, _res, {:call, _, :start, [thread, run, ordinal, _new?, _first?]}) do
    s =
      s
      |> update_in([:threads], &Map.put_new(&1, thread, %{runs: [], base: 0}))
      |> update_in(
        [:threads, thread, :runs],
        &(&1 ++ [%{id: run, ordinal: ordinal, status: "running", tools: []}])
      )
      |> put_in([:open, thread], run)
      |> Map.update!(:runs, &(&1 + 1))

    cond do
      not s.up ->
        s

      # It reads the thread's history as the turn starts, unless it already did.
      s.history and thread not in s.read ->
        read =
          for run <- ended(s.threads[thread].runs),
              {tool, period, :own} <- run.tools,
              period != s.period,
              do: tool

        %{
          s
          | owed: Enum.uniq(s.owed ++ read),
            read: [thread | s.read],
            heard: Enum.uniq([thread | s.heard])
        }

      true ->
        %{s | heard: Enum.uniq([thread | s.heard])}
    end
  end

  def next_state(s, _res, {:call, _, :use, [thread, _run, _n, tool, drop, via]}) do
    period = if s.up and drop, do: s.period
    runs = s.threads[thread].runs
    last = List.last(runs)

    s =
      put_in(
        s.threads[thread].runs,
        List.replace_at(runs, -1, %{last | tools: last.tools ++ [{tool, period, via}]})
      )

    s = %{s | used: Enum.uniq(s.used ++ [tool])}

    if s.up and not drop and thread in s.heard,
      do: %{s | owed: Enum.uniq(s.owed ++ [tool])},
      else: s
  end

  def next_state(s, _res, {:call, _, :finish, [thread, _run, _]}) do
    runs = s.threads[thread].runs
    last = List.last(runs)
    s = put_in(s.threads[thread].runs, List.replace_at(runs, -1, %{last | status: "completed"}))
    %{s | open: Map.delete(s.open, thread)}
  end

  def next_state(s, _res, {:call, _, :mode, [mode]}), do: %{s | mode: mode}
  def next_state(s, _res, {:call, _, :down, _}), do: %{s | up: false, heard: [], read: []}
  def next_state(s, _res, {:call, _, :up, _}), do: %{s | up: true, period: s.period + 1}
  def next_state(s, _res, {:call, _, :history, [on]}), do: %{s | history: on}

  def next_state(s, _res, {:call, _, :rollback, [thread, runs]}) do
    ids = Enum.map(runs, &elem(&1, 0))

    update_in(s.threads[thread].runs, fn all ->
      Enum.map(all, &if(&1.id in ids, do: %{&1 | status: "rolled_back"}, else: &1))
    end)
  end

  def next_state(s, _res, {:call, _, :fork, [_source, copies]}) do
    base = copies |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    %{s | forked: true, threads: Map.put(s.threads, "f", %{runs: [], base: base})}
  end

  def next_state(s, _res, _call), do: s

  def postcondition(_s, {:call, _, :down, _}, %{held: held, kept: kept}), do: held == kept
  def postcondition(_s, _call, %{down: true}), do: true

  def postcondition(s, call, res) do
    next = next_state(s, res, call)
    denied = Map.get(res, :denied, [])

    subset?(next.owed, res.used) and subset?(res.used, next.used) and
      disjoint?(res.proposal, next.owed) and disjoint?(denied, next.owed) and
      res.prompts <= next.runs and
      Enum.all?(@tools, &(streak(res, &1) <= unused_runs(next, &1)))
  end

  defp streak(res, tool),
    do: max(res.streaks[tool]["prompts"] || 0, res.live_streaks[tool]["prompts"] || 0)

  # The thread's turns that ended (or were rolled back after) without using `tool`.
  defp unused_runs(s, tool) do
    for {_t, %{runs: runs}} <- s.threads,
        run <- runs,
        run.status != "running",
        tool not in tools(run),
        reduce: 0,
        do: (n -> n + 1)
  end

  defp subset?(a, b), do: Enum.all?(a, &(&1 in b))
  defp disjoint?(a, b), do: not Enum.any?(a, &(&1 in b))

  defp ended(runs), do: Enum.filter(runs, &(&1.status == "completed"))
  defp tools(run), do: Enum.map(run.tools, &elem(&1, 0))
  defp current(s, thread), do: List.last(s.threads[thread].runs)

  defp next_ordinal(s, thread) do
    case s.threads[thread] do
      nil -> 1
      %{runs: runs, base: base} -> base + length(runs) + 1
    end
  end

  # --- the commands ------------------------------------------------------------------------

  # A turn starts: the MC writes its run, asks the plugins to shape a new
  # conversation, and tells them it started.
  def start(thread, run, ordinal, new?, first?) do
    if first?,
      do:
        commit(thread, [
          {"thread", thread, %{"s" => %{}}},
          {"provider-thread", "pt-#{thread}", %{"s" => %{"driver" => @provider}}}
        ])

    commit(thread, [run_row(thread, run, ordinal, "running")])

    if Process.get(:plugin) do
      event = %{
        "threadId" => thread,
        "runId" => run,
        "projectId" => @project_id,
        "provider" => @provider
      }

      shape = if new?, do: call({:shape, event})

      deliver(Map.merge(event, %{"type" => "turn.started", "newConversation" => new?}))

      snapshot(%{denied: (shape || %{})["deniedTools"] || []})
    else
      snapshot()
    end
  end

  # The turn uses a tool, or a subagent working in it does (kept in the child's thread,
  # so the turn's history shows only the subagent); the feed may drop the use, and
  # says so with its next event.
  def use(thread, run, n, tool, drop, via) do
    commit(thread, [item_row(run, n, {tool, via})])

    cond do
      Process.get(:plugin) == nil ->
        :ok

      drop ->
        Process.put(:drop, true)

      true ->
        deliver(
          %{
            "type" => "turn.item",
            "threadId" => thread,
            "runId" => run,
            "itemType" => "dynamic_tool_call",
            "tool" => tool,
            "status" => "completed"
          }
          |> Map.merge(if(via == :subagent, do: %{"subagent" => true}, else: %{}))
        )
    end

    snapshot()
  end

  def finish(thread, run, ordinal) do
    commit(thread, [run_row(thread, run, ordinal, "completed")])

    if Process.get(:plugin),
      do:
        deliver(%{
          "type" => "turn.finished",
          "threadId" => thread,
          "runId" => run,
          "ordinal" => ordinal,
          "status" => "completed"
        })

    snapshot()
  end

  # The quiet timer fires.
  def tick do
    with %{} = plugin <- Process.get(:plugin) do
      {:noreply, plugin} = TokenEconomizer.handle_info({:toolprune_tick, @project}, plugin)
      Process.put(:plugin, plugin)
    end

    snapshot()
  end

  def mode(mode) do
    Process.put(:mode, mode)
    if Process.get(:plugin), do: call({:settings, settings(mode)})
    snapshot()
  end

  def apply_tools(tools), do: person(:apply, tools)
  def restore(tools), do: person(:restore, tools)

  defp person(action, tools) do
    if Process.get(:plugin) do
      input = %{"projectId" => @project_id, "provider" => @provider, "tools" => tools}
      call({:toolprune, action, input})
    end

    snapshot()
  end

  # The plugin stops: what it held of the project, and what its file keeps.
  def down do
    plugin = Process.get(:plugin)
    held = plugin.prunes[@project]
    stop_plugin()
    Process.delete(:drop)
    %{held: kept(held), kept: if(held, do: kept(Prune.new("tool", saved())))}
  end

  def up do
    start_plugin()
    snapshot()
  end

  def history(on) do
    grant(on)
    snapshot()
  end

  def rollback(thread, runs) do
    commit(thread, for({id, ordinal} <- runs, do: run_row(thread, id, ordinal, "rolled_back")))
    snapshot()
  end

  def fork(source, copies) do
    rows =
      for {id, ordinal, tools} <- copies,
          row <- [
            run_row(source, "f-#{id}", ordinal, "completed")
            | for({use, n} <- Enum.with_index(tools, 1), do: item_row("f-#{id}", n, use))
          ],
          do: row

    commit(
      "f",
      [
        {"thread", "f", %{"s" => %{}}},
        {"provider-thread", "pt-f", %{"s" => %{"driver" => @provider}}}
      ] ++ rows
    )

    snapshot()
  end

  # --- helpers -----------------------------------------------------------------------------

  defp call(message) do
    {:reply, reply, plugin} = TokenEconomizer.handle_call(message, nil, Process.get(:plugin))
    Process.put(:plugin, plugin)
    reply
  end

  # The feed's next event, saying it dropped one if it did.
  defp deliver(event) do
    event =
      if Process.delete(:drop),
        do: Map.merge(event, %{"dropped" => 1, "waiting" => 0}),
        else: event

    :ok = call({:observe, event})
  end

  # What the plugin holds of the project, read from its file while it holds none.
  defp snapshot(extra \\ %{}) do
    case Process.get(:plugin) do
      nil ->
        Map.put(extra, :down, true)

      plugin ->
        prune = plugin.prunes[@project] || Prune.new("tool", saved())
        cfg = Prune.config(plugin.settings)

        Map.merge(extra, %{
          used: prune["used"],
          prompts: prune["prompts"],
          streaks: prune["streaks"],
          live_streaks: prune["liveStreaks"],
          proposal: Prune.proposal(prune, cfg)
        })
    end
  end

  # What a restart reads back: everything but when the project was last active, the
  # threads' watermarks and counted conversations, and what auto held (each read
  # afresh or recomputed as the next conversation starts).
  defp kept(nil), do: nil

  defp kept(prune),
    do: Map.drop(prune, ~w(lastActivity seededThreads countedThreads liveThreads pending))

  defp saved do
    with {:ok, text} <- File.read(TokenEconomizer.toolprune_path(@project)),
         {:ok, %{} = saved} <- JSON.decode(text) do
      saved
    else
      _ -> %{}
    end
  end

  defp commit(thread, rows), do: {:ok, _} = HalC2.Streams.commit(thread, :thread, rows)

  # The run written to the stream; a fork's copies keep the source's provider thread.
  defp run_row(thread, run, ordinal, status),
    do:
      {"run", run,
       %{
         "s" => %{
           "id" => run,
           "ordinal" => ordinal,
           "status" => status,
           "providerThreadId" => "pt-#{thread}"
         }
       }}

  # A use the turn's own item records, or the item of the subagent that made it.
  defp item_row(run, n, {tool, via}) do
    use =
      if via == :subagent,
        do: %{"type" => "subagent", "subagentId" => "#{run}-s#{n}"},
        else: %{"type" => "dynamic_tool_call", "providerToolName" => tool}

    {"turn-item", "#{run}-i#{n}",
     %{
       "s" =>
         Map.merge(use, %{
           "id" => "#{run}-i#{n}",
           "runId" => run,
           "ordinal" => n,
           "status" => "completed"
         })
     }}
  end
end
