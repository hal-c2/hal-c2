for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge tool_prune_evidence token_economizer),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerToolPrunePluginPropTest do
  @moduledoc """
  A state machine model of TokenEconomizer's tool pruning in its process
  (`HalC2Plugins.TokenEconomizer`): the Claude turns of two threads of one project,
  each written to the thread's stream as the MC writes it and heard through the feed,
  which may drop a tool use and say so with its next event, or tell of one after its
  turn ended, also to a plugin that restarted since the turn started and so has heard
  nothing of it (each item names its thread's project). A use may be a subagent's,
  heard as its parent turn's but kept in the child's thread: the parent's history
  shows only that a subagent worked in the turn. The plugin stops and
  starts again (missing whatever ran meanwhile), its history reads fail while it has
  no grant, a thread rolls turns back and is forked, a thread is deleted (perhaps
  while a turn runs, which then never ends here), the mode moves between off,
  propose and auto, and the person applies and restores tools. After every step:

  - every use the plugin must know of is in its evidence's used list: one it heard,
    and, once it read a thread's history after starting, any of the thread's turns
    that ended and are still in it, the uses dropped since it started aside (those
    it reads back as their conversation folds, which the model does not follow), and
    the subagents' (which no history read shows);
  - it uses no tool no turn used;
  - no tool it must know is used is proposed, or turned off for a new conversation;
  - a new conversation is turned off no tool a segment it heard in part used, dropped
    use or not, in a turn the history still has or that still runs, nor one that
    folded before it could be read back, and nothing at all when that history cannot
    be read;
  - no tool used in the scope is ever denied: a new conversation is turned off no
    tool whose use the feed dropped from a conversation the plugin holds and then said
    it dropped, while the turn is not rolled back, however the segment folded since
    (one a quiet project folded before the feed said so is the known limit: it folds
    as evidence, the Maude model's `unseenOff`);
  - no tool's streak counts more ended turns than those that did not use it, so a
    use it missed and could not read back is no evidence the tool went unused (a
    tool it knows is used is never proposed or turned off, so a use told of after its
    turn folded may leave that tool's streak as it was);
  - a deleted thread holds nothing off: a conversation shaped while the history can
    be read, when the only segments heard in part are deleted threads', is turned
    off all the evidence turns off, and no deleted thread is left to read back
    (what a deleted thread used reaches no conversation, so none of the above
    counts its uses);
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

  # Interleavings the generator seldom reaches, each a way recovery fell short: a
  # subagent's use heard as the plugin restarted, before its thread's next turn; a
  # dropped use in a turn still under way, which no history read shows yet; and a
  # segment heard in part that a quiet project folded while its history could not be
  # read, then another thread's conversation; and one folded while its turn ran,
  # whose thread is then deleted.
  @pinned [
    restart: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      down: [],
      up: [],
      use: ["a", "r1", 1, "CronCreate", false, :subagent],
      start: ["b", "r2", 1, true, true]
    ],
    running: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      use: ["a", "r1", 1, "CronCreate", true, :own],
      start: ["b", "r2", 1, false, true],
      finish: ["b", "r2", 1],
      start: ["b", "r3", 2, true, false]
    ],
    quiet: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      use: ["a", "r1", 1, "CronCreate", true, :own],
      finish: ["a", "r1", 1],
      history: [false],
      tick: [],
      start: ["b", "r2", 1, true, true],
      finish: ["b", "r2", 1],
      history: [true],
      start: ["b", "r3", 2, true, false]
    ],
    gone: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      finish: ["a", "r1", 1],
      start: ["b", "r2", 1, true, true],
      use: ["b", "r2", 1, "CronCreate", true, :own],
      start: ["a", "r3", 2, false, false],
      finish: ["a", "r3", 2],
      tick: [],
      thread_gone: ["b"],
      start: ["a", "r4", 3, true, false]
    ],
    away: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      finish: ["a", "r1", 1],
      start: ["b", "r2", 1, true, true],
      use: ["b", "r2", 1, "CronCreate", true, :own],
      start: ["a", "r3", 2, false, false],
      finish: ["a", "r3", 2],
      tick: [],
      thread_moved: ["b", "r2", 1],
      start: ["a", "r4", 3, true, false],
      finish: ["a", "r4", 3],
      thread_returned: ["b"],
      start: ["a", "r5", 4, true, false]
    ],
    # b's turn ends here, then turns it runs on the other MC push it out of the
    # last page of its history.
    window: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      finish: ["a", "r1", 1],
      start: ["b", "r2", 1, true, true],
      use: ["b", "r2", 1, "CronCreate", true, :own],
      start: ["a", "r3", 2, false, false],
      finish: ["a", "r3", 2],
      tick: [],
      finish: ["b", "r2", 1],
      thread_moved: ["b", nil, nil],
      ran_away: ["b", "r4", 2],
      ran_away: ["b", "r5", 3],
      ran_away: ["b", "r6", 4],
      ran_away: ["b", "r7", 5],
      thread_returned: ["b"],
      start: ["a", "r8", 3, true, false]
    ],
    stray: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      finish: ["a", "r1", 1],
      down: [],
      up: [],
      stray_use: ["a", "CronCreate"],
      start: ["b", "r2", 1, true, true],
      start: ["a", "r3", 2, false, false],
      finish: ["b", "r2", 1],
      start: ["b", "r4", 2, true, false]
    ],
    # A restart keeps a use heard with no project, till its thread's record names one.
    stray_kept: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      finish: ["a", "r1", 1],
      down: [],
      up: [],
      stray_use: ["a", "CronCreate"],
      down: [],
      up: [],
      start: ["b", "r2", 1, true, true],
      finish: ["b", "r2", 1],
      thread_placed: ["a"],
      start: ["b", "r3", 2, true, false]
    ],
    # Saved uses that cannot be read hold pruning off, shown, till a person's word.
    unreadable: [
      start: ["a", "r1", 1, true, true],
      apply_tools: [["CronCreate"]],
      finish: ["a", "r1", 1],
      down: [],
      corrupt_strays: [],
      up: [],
      apply_elsewhere: [nil],
      apply_elsewhere: ["claudeAgent"],
      down: [],
      up: [],
      start: ["b", "r2", 1, true, true],
      finish: ["b", "r2", 1],
      apply_tools: [["CronCreate"]],
      down: [],
      up: [],
      start: ["b", "r3", 2, true, false]
    ]
  ]

  for {name, _} <- @pinned do
    test "no tool used in the scope is denied: #{name}" do
      calls = @pinned[unquote(name)]

      cmds =
        for {{f, args}, i} <- Enum.with_index(calls, 1),
            do: {:set, {:var, i}, {:call, __MODULE__, f, args}}

      open_case()
      {history, state, result} = run_commands(__MODULE__, cmds)
      close_case()
      assert result == :ok, HalC2.Prop.report(cmds, history, state, result)
    end
  end

  defp open_case do
    home = HalC2.Prop.scratch_home("token-economizer-prune")
    File.write!(Path.join(home, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    # Pages of 3 runs, so a segment's runs fall behind the last page.
    Application.put_env(:hal_c2, :token_economizer_history_page, 3)

    HalC2.Prop.start_services([
      HalC2.Settings,
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams
    ])

    grant(true)
    # The project's evidence is kept from the start, empty, so a person's call on it
    # acts on it, however little the plugin heard yet (`apply_elsewhere/1` fails).
    path = TokenEconomizer.toolprune_path(@project)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")
    Process.put(:mode, "propose")
    start_plugin()
  end

  defp close_case do
    stop_plugin()
    Process.delete(:mode)
    Process.delete(:drop)
    HalC2.Prop.stop_services()
    Application.delete_env(:hal_c2, :settings_check_ms)
    Application.delete_env(:hal_c2, :token_economizer_history_page)
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
  # `lost`: the own uses the feed dropped from a conversation the plugin holds, as
  # `%{thread, run, tool, period, told}`, `told` once the feed said it dropped them.
  # `named`: the tools the person last turned off by name, which turns go on to use
  # more often than others (a conversation shaped before still has them). `gone`: the
  # deleted threads. `away`: those moved to another MC, which may come back. `strays`:
  # `{thread, tool}`, a subagent's uses heard with no project while its thread's record
  # names none, kept across restarts until a turn of its or its record names one.
  # `placed`: the threads whose record names their project. `unreadable`: whether saved
  # uses that could not be read hold the provider off, till a person's word.
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
      lost: [],
      named: [],
      used: [],
      runs: 0,
      forked: false,
      gone: [],
      away: [],
      strays: [],
      placed: [],
      unreadable: false
    }

  def command(s) do
    threads = (@threads ++ if(s.forked, do: ["f"], else: [])) -- (s.gone ++ s.away)
    open = Map.keys(s.open)
    idle = threads -- open
    live = Map.keys(s.threads) -- s.gone
    here = live -- s.away
    unplaced = live -- s.placed

    rollbackable =
      for {t, %{runs: runs}} <- s.threads, t in here, t not in open, ended(runs) != [], do: t

    forkable =
      if s.forked,
        do: [],
        else: for({t, _} <- s.threads, t in @threads, t in here, t not in open, do: t)

    tools = oneof([nil, elements(Enum.map(@tools, &[&1]))])

    # Turns that ended, also of threads the plugin has heard nothing of since it started.
    closed =
      for {t, %{runs: runs}} <- s.threads, t in here, s.up, run <- ended(runs), do: {t, run}

    [
      idle != [] and s.runs < @max_runs and {6, start_call(s, idle)},
      idle != [] and s.runs < @max_runs and {2, late_call(s, idle)},
      open != [] and {8, use_call(s, open)},
      closed != [] and {2, late_use_call(closed)},
      open != [] and {5, finish_call(s, open)},
      {2, {:call, __MODULE__, :tick, []}},
      {1, {:call, __MODULE__, :mode, [elements(~w(off propose auto))]}},
      {2, {:call, __MODULE__, :apply_tools, [tools, boolean()]}},
      {1, {:call, __MODULE__, :restore, [tools, boolean()]}},
      {1, {:call, __MODULE__, :apply_elsewhere, [elements([nil, @provider])]}},
      s.up and {1, {:call, __MODULE__, :down, []}},
      not s.up and {3, {:call, __MODULE__, :up, []}},
      {1, {:call, __MODULE__, :history, [not s.history]}},
      rollbackable != [] and {1, rollback_call(s, rollbackable)},
      forkable != [] and {1, fork_call(s, forkable)},
      live != [] and {1, {:call, __MODULE__, :thread_gone, [elements(live)]}},
      here != [] and {1, moved_call(s, here)},
      s.away != [] and {2, {:call, __MODULE__, :thread_returned, [elements(s.away)]}},
      s.away != [] and s.runs < @max_runs and {2, ran_away_call(s)},
      s.up and here != [] and
        {1, {:call, __MODULE__, :stray_use, [elements(here), elements(@tools)]}},
      unplaced != [] and {1, {:call, __MODULE__, :thread_placed, [elements(unplaced)]}},
      not s.up and {1, {:call, __MODULE__, :corrupt_strays, []}}
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

  # A turn that ends before the feed tells of it starting, the quiet timer perhaps
  # firing between.
  defp ran_away_call(s) do
    let thread <- elements(s.away) do
      {:call, __MODULE__, :ran_away, [thread, "r#{s.runs + 1}", next_ordinal(s, thread)]}
    end
  end

  # Its turn under way, if any, ends on the other MC.
  defp moved_call(s, threads) do
    let thread <- elements(threads) do
      run = s.open[thread] && List.last(s.threads[thread].runs)
      {:call, __MODULE__, :thread_moved, [thread, run && run.id, run && run.ordinal]}
    end
  end

  defp late_call(s, idle) do
    let [{:call, m, :start, args} <- start_call(s, idle), tick? <- boolean()] do
      {:call, m, :late, args ++ [tick?]}
    end
  end

  defp use_call(s, open) do
    let [
      thread <- elements(open),
      tool <- tool(s),
      drop <- frequency([{3, false}, {1, true}]),
      via <- frequency([{3, :own}, {1, :subagent}])
    ] do
      run = s.open[thread]
      n = length(current(s, thread).tools) + 1
      {:call, __MODULE__, :use, [thread, run, n, tool, drop, via]}
    end
  end

  defp tool(%{named: []}), do: elements(@tools)
  defp tool(s), do: frequency([{1, elements(@tools)}, {2, elements(s.named)}])

  # A use the feed tells of after its turn ended: a subagent of the turn's still at
  # work, or an item the provider reported late. One the feed dropped too is a use
  # neither it nor a history read (each run folds once) shows, which the Maude model's
  # `unseenOff` keeps as the design's known limit.
  defp late_use_call(closed) do
    let [
      {thread, run} <- elements(closed),
      tool <- elements(@tools),
      via <- frequency([{3, :own}, {1, :subagent}])
    ] do
      {:call, __MODULE__, :late_use, [thread, run.id, length(run.tools) + 1, tool, via]}
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
    do:
      not Map.has_key?(s.open, thread) and s.runs < @max_runs and
        thread not in (s.gone ++ s.away)

  def precondition(s, {:call, m, :late, [thread, run, ordinal, new?, first?, _]}),
    do: precondition(s, {:call, m, :start, [thread, run, ordinal, new?, first?]})

  def precondition(s, {:call, _, :use, [thread, run | _]}), do: s.open[thread] == run
  def precondition(s, {:call, _, :finish, [thread, run, _]}), do: s.open[thread] == run

  def precondition(s, {:call, _, :late_use, [thread, run, n | _]}) do
    s.up and thread not in (s.gone ++ s.away) and
      Enum.any?(
        ended(s.threads[thread][:runs] || []),
        &(&1.id == run and length(&1.tools) + 1 == n)
      )
  end

  def precondition(s, {:call, _, :down, _}), do: s.up
  def precondition(s, {:call, _, :up, _}), do: not s.up

  def precondition(s, {:call, _, :rollback, [thread, runs]}) do
    not Map.has_key?(s.open, thread) and thread not in (s.gone ++ s.away) and runs != [] and
      Enum.all?(runs, fn {id, _} ->
        id in Enum.map(ended(s.threads[thread][:runs] || []), & &1.id)
      end)
  end

  def precondition(s, {:call, _, :fork, [source, _]}),
    do: not s.forked and not Map.has_key?(s.open, source) and source not in (s.gone ++ s.away)

  def precondition(s, {:call, _, :thread_gone, [thread]}),
    do: Map.has_key?(s.threads, thread) and thread not in s.gone

  def precondition(s, {:call, _, :thread_moved, [thread, run, _]}),
    do:
      Map.has_key?(s.threads, thread) and thread not in (s.gone ++ s.away) and
        s.open[thread] == run

  def precondition(s, {:call, _, :thread_returned, [thread]}), do: thread in s.away

  def precondition(s, {:call, _, :ran_away, [thread, _run, ordinal]}),
    do: thread in s.away and s.runs < @max_runs and ordinal == next_ordinal(s, thread)

  def precondition(s, {:call, _, :stray_use, [thread, _tool]}),
    do: s.up and Map.has_key?(s.threads, thread) and thread not in (s.gone ++ s.away)

  def precondition(s, {:call, _, :corrupt_strays, []}), do: not s.up

  def precondition(s, {:call, _, :thread_placed, [thread]}),
    do: Map.has_key?(s.threads, thread) and thread not in (s.placed ++ s.gone)

  def precondition(_s, _call), do: true

  def next_state(s, _res, {:call, _, :start, [thread, run, ordinal, new?, _first?]}) do
    s =
      s
      |> told()
      |> update_in([:threads], &Map.put_new(&1, thread, %{runs: [], base: 0}))
      |> update_in(
        [:threads, thread, :runs],
        &(&1 ++ [%{id: run, ordinal: ordinal, status: "running", tools: []}])
      )
      |> put_in([:open, thread], run)
      |> Map.update!(:runs, &(&1 + 1))

    # Its turn names its project, which the uses heard with none are then the evidence
    # of; so does, as a conversation is shaped, the record of any thread that names it,
    # when the record can be read.
    {settled, strays} =
      Enum.split_with(s.strays, fn {t, _} ->
        s.up and (t == thread or (new? and s.history and t in s.placed))
      end)

    s = %{s | strays: strays, owed: Enum.uniq(s.owed ++ Enum.map(settled, &elem(&1, 1)))}

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

  def next_state(s, res, {:call, m, :late, [thread, run, ordinal, new?, first?, tick?]}) do
    s
    |> then(&if(tick?, do: untold(&1), else: &1))
    |> next_state(res, {:call, m, :start, [thread, run, ordinal, new?, first?]})
    |> next_state(res, {:call, m, :finish, [thread, run, ordinal]})
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

    cond do
      not s.up ->
        s

      drop and via == :own and thread in s.heard ->
        lost = %{thread: thread, run: last.id, tool: tool, period: s.period, told: false}
        %{s | lost: s.lost ++ [lost]}

      drop ->
        s

      # Heard as it ends, whether or not the plugin holds its conversation.
      true ->
        %{told(s) | owed: Enum.uniq(s.owed ++ [tool])}
    end
  end

  def next_state(s, _res, {:call, _, :late_use, [thread, run, _n, tool, via]}) do
    s =
      update_in(s.threads[thread].runs, fn runs ->
        Enum.map(
          runs,
          &if(&1.id == run, do: %{&1 | tools: &1.tools ++ [{tool, nil, via}]}, else: &1)
        )
      end)

    %{told(s) | used: Enum.uniq(s.used ++ [tool]), owed: Enum.uniq(s.owed ++ [tool])}
  end

  def next_state(s, _res, {:call, _, :finish, [thread, _run, _]}) do
    runs = s.threads[thread].runs
    last = List.last(runs)
    s = put_in(s.threads[thread].runs, List.replace_at(runs, -1, %{last | status: "completed"}))
    %{told(s) | open: Map.delete(s.open, thread)}
  end

  def next_state(s, _res, {:call, _, :tick, _}), do: untold(s)

  # A person's word releases the hold on uses that could not be read: changing the
  # mode, or applying or restoring the provider's tools.
  def next_state(s, _res, {:call, _, :mode, [mode]}),
    do: %{s | mode: mode, unreadable: s.unreadable and not (s.up and mode != s.mode)}

  # Naming the project alone acts on the same evidence, held or on file.
  def next_state(s, _res, {:call, _, :apply_tools, [tools | _]}),
    do: %{s | named: tools || [], unreadable: s.unreadable and not s.up}

  def next_state(s, _res, {:call, _, :restore, [tools | _]}),
    do: %{s | named: s.named -- (tools || s.named), unreadable: s.unreadable and not s.up}

  def next_state(s, _res, {:call, _, :corrupt_strays, []}), do: %{s | unreadable: true}

  # The uses heard with no project are kept.
  def next_state(s, _res, {:call, _, :down, _}),
    do: untold(%{s | up: false, heard: [], read: []})

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

  # A turn under way never ends here.
  def next_state(s, _res, {:call, _, :thread_gone, [thread]}),
    do: %{
      s
      | gone: [thread | s.gone],
        away: List.delete(s.away, thread),
        open: Map.delete(s.open, thread)
    }

  # Its turn under way ends there, unheard here; the history it comes back with has it.
  def next_state(s, _res, {:call, _, :thread_moved, [thread, run, _]}) do
    s = %{s | away: [thread | s.away], open: Map.delete(s.open, thread)}

    if run,
      do:
        update_in(s.threads[thread].runs, fn runs ->
          List.replace_at(runs, -1, %{List.last(runs) | status: "completed"})
        end),
      else: s
  end

  def next_state(s, _res, {:call, _, :thread_returned, [thread]}),
    do: %{s | away: List.delete(s.away, thread)}

  def next_state(s, _res, {:call, _, :ran_away, [thread, run, ordinal]}) do
    s
    |> update_in(
      [:threads, thread, :runs],
      &(&1 ++ [%{id: run, ordinal: ordinal, status: "completed", tools: []}])
    )
    |> Map.update!(:runs, &(&1 + 1))
  end

  # With no project of its own, the use is its thread's record's project's at once,
  # when the record can be read.
  def next_state(s, _res, {:call, _, :stray_use, [thread, tool]}) do
    s = %{told(s) | used: Enum.uniq(s.used ++ [tool])}

    if thread in s.placed and s.history,
      do: %{s | owed: Enum.uniq(s.owed ++ [tool])},
      else: %{s | strays: Enum.uniq(s.strays ++ [{thread, tool}])}
  end

  def next_state(s, _res, {:call, _, :thread_placed, [thread]}),
    do: %{s | placed: [thread | s.placed]}

  def next_state(s, _res, _call), do: s

  # The feed delivers an event, which says what it dropped before it.
  defp told(%{up: true} = s), do: %{s | lost: Enum.map(s.lost, &%{&1 | told: true})}
  defp told(s), do: s

  # A quiet project folds the segments it holds before the feed said what it dropped
  # from them, as evidence: those uses are the known limit. A restart loses the report.
  defp untold(s), do: %{s | lost: Enum.filter(s.lost, & &1.told)}

  def postcondition(_s, {:call, _, :down, _}, %{held: held, kept: kept}), do: held == kept
  def postcondition(_s, _call, %{down: true}), do: true

  def postcondition(s, call, res) do
    next = next_state(s, res, call)
    denied = Map.get(res, :denied, [])

    subset?(next.owed, res.used) and subset?(res.used, next.used) and
      disjoint?(res.proposal, next.owed) and disjoint?(denied, next.owed) and
      shaped_whole?(s, res, denied) and disjoint?(denied, lost(s)) and gone_holds_nothing?(s, res) and
      disjoint?(denied, strayed(s)) and (denied == [] or not s.unreadable) and
      res.unreadable == next.unreadable and
      res.prompts <= ended_runs(next) and
      Enum.all?(@tools -- res.used, &(streak(res, &1) <= unused_runs(next, &1)))
  end

  # A conversation is shaped knowing the uses of the segments heard in part that the
  # history still has or that still run, dropped ones too, or, when it cannot read
  # them, denied nothing.
  defp shaped_whole?(s, res, denied) do
    partial = Map.get(res, :partial, [])

    recovered =
      for {t, ids} <- partial,
          t not in (s.gone ++ s.away),
          run <- s.threads[t].runs,
          run.id in ids and run.status != "rolled_back",
          {tool, _period, :own} <- run.tools,
          do: tool

    cond do
      partial == [] -> true
      s.history -> disjoint?(denied, recovered)
      true -> denied == []
    end
  end

  # Saved uses that could not be read hold it off whatever else does.
  # A deleted thread's segments heard in part neither hold a conversation's shape off
  # nor stay to be read back, once the history can be read. Those of a thread on
  # another MC hold nothing off either, but stay: once it is back, `lost/1` and
  # `shaped_whole?/3` count them again.
  defp gone_holds_nothing?(s, %{shaped: true} = res) do
    partial = for {t, _} <- res.partial, do: t

    cond do
      s.unreadable ->
        true

      partial == [] ->
        res.denied == res.deniable

      not s.history ->
        true

      true ->
        disjoint?(res.unresolved, s.gone) and
          (not subset?(partial, s.gone ++ s.away) or res.denied == res.deniable)
    end
  end

  defp gone_holds_nothing?(_s, _res), do: true

  # The uses dropped from the conversations the plugin holds that the feed said it
  # dropped, of turns not rolled back, nor of a thread deleted or, for now, away.
  defp lost(s) do
    for %{told: true, period: period, thread: t, run: id, tool: tool} <- s.lost,
        period == s.period,
        t not in (s.gone ++ s.away),
        Enum.any?(s.threads[t].runs, &(&1.id == id and &1.status != "rolled_back")),
        do: tool
  end

  # The uses heard with no project, of threads neither deleted nor, for now, away.
  defp strayed(s), do: for({t, tool} <- s.strays, t not in (s.gone ++ s.away), do: tool)

  defp streak(res, tool),
    do: max(res.streaks[tool]["prompts"] || 0, res.live_streaks[tool]["prompts"] || 0)

  # The turns that ended (or were rolled back after): each folds once, heard live or
  # read back, however late the feed tells of it.
  defp ended_runs(s) do
    for {_t, %{runs: runs}} <- s.threads,
        run <- runs,
        run.status != "running",
        reduce: 0,
        do: (n -> n + 1)
  end

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
    begin(thread, run, ordinal, first?)
    started(thread, run, new?)
  end

  def late(thread, run, ordinal, new?, first?, tick?) do
    begin(thread, run, ordinal, first?)
    commit(thread, [run_row(thread, run, ordinal, "completed")])
    if tick?, do: tick()
    res = started(thread, run, new?)
    finish(thread, run, ordinal)
    res
  end

  defp begin(thread, run, ordinal, first?) do
    if first?,
      do:
        commit(thread, [
          {"thread", thread, %{"s" => %{}}},
          {"provider-thread", "pt-#{thread}", %{"s" => %{"driver" => @provider}}}
        ])

    commit(thread, [run_row(thread, run, ordinal, "running")])
  end

  defp started(thread, run, new?) do
    if Process.get(:plugin) do
      event = %{
        "threadId" => thread,
        "runId" => run,
        "projectId" => @project_id,
        "provider" => @provider
      }

      # The segments it holds as heard in part as the conversation is shaped, and
      # their runs, and those that folded before they could be read back: which those
      # are is the feed's to say (`missed/2`), not the model's.
      plugin = Process.get(:plugin)

      partial =
        for({t, %{partial: true, runs: runs}} <- plugin.convs, do: {t, runs}) ++
          for({{t, _}, marks} <- Map.get(plugin, :unresolved, %{}), do: {t, marks}) ++
          for({{t, _}, _} <- Map.get(plugin, :strays, %{}), is_binary(t), do: {t, []})

      partial = for {t, marks} <- partial, do: {t, Enum.map(marks, & &1["run"])}

      shape = if new?, do: call({:shape, event})
      plugin = Process.get(:plugin)

      # What the evidence turns off as the conversation is shaped, and the threads
      # still to read back.
      shaped =
        if new?,
          do: %{
            shaped: true,
            deniable: Prune.denied(plugin.prunes[@project], Prune.config(plugin.settings)),
            unresolved: for({{t, _}, _} <- plugin.unresolved, do: t)
          },
          else: %{}

      deliver(Map.merge(event, %{"type" => "turn.started", "newConversation" => new?}))
      denied = (shape || %{})["deniedTools"] || []

      snapshot(Map.merge(shaped, %{denied: denied, partial: if(new?, do: partial, else: [])}))
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
            "projectId" => @project_id,
            "provider" => @provider,
            "itemType" => "dynamic_tool_call",
            "tool" => tool,
            "status" => "completed"
          }
          |> Map.merge(if(via == :subagent, do: %{"subagent" => true}, else: %{}))
        )
    end

    snapshot()
  end

  def late_use(thread, run, n, tool, via) do
    commit(thread, [item_row(run, n, {tool, via})])

    deliver(
      %{
        "type" => "turn.item",
        "threadId" => thread,
        "runId" => run,
        "projectId" => @project_id,
        "provider" => @provider,
        "itemType" => "dynamic_tool_call",
        "tool" => tool,
        "status" => "completed"
      }
      |> Map.merge(if(via == :subagent, do: %{"subagent" => true}, else: %{}))
    )

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

  # `provider?`: whether the call names the provider too, or only the project, which is
  # then each pruning provider's evidence, held or on file (after `up/0` only on file).
  def apply_tools(tools, provider? \\ true), do: person(:apply, tools, provider?)
  def restore(tools, provider? \\ true), do: person(:restore, tools, provider?)

  # A person applies tools to a project the plugin has no evidence of, for `provider` or
  # every provider: the call fails, and changes nothing.
  def apply_elsewhere(provider) do
    if plugin = Process.get(:plugin) do
      input = %{"projectId" => "nowhere", "provider" => provider, "tools" => nil}
      {:error, _} = call({:toolprune, :apply, Map.reject(input, fn {_, v} -> v == nil end)})
      true = Process.get(:plugin) == plugin
    end

    snapshot()
  end

  defp person(action, tools, provider?) do
    if Process.get(:plugin) do
      input = %{"projectId" => @project_id, "tools" => tools}
      input = if provider?, do: Map.put(input, "provider", @provider), else: input
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

  # The thread is deleted, a turn under way perhaps, which then never ends here.
  def thread_gone(thread) do
    commit(thread, [{"thread", thread, %{"s" => %{"deletedAt" => "2026-11-09T00:00:00Z"}}}])
    snapshot()
  end

  # The thread moves to another MC, which ends its turn under way.
  def thread_moved(thread, run, ordinal) do
    moved = %{"mc" => "elsewhere@host", "label" => "Elsewhere", "at" => "2026-11-09T00:00:00Z"}
    ended = if run, do: [run_row(thread, run, ordinal, "completed")], else: []
    commit(thread, [{"thread", thread, %{"s" => %{"movedTo" => moved}}} | ended])
    snapshot()
  end

  # It runs a turn on the other MC, which its history has once it is back.
  def ran_away(thread, run, ordinal) do
    commit(thread, [run_row(thread, run, ordinal, "completed")])
    snapshot()
  end

  # A subagent of the thread's, its handle from before it kept its run and project,
  # uses `tool` (its child thread keeps the call).
  def stray_use(thread, tool) do
    deliver(%{
      "type" => "turn.item",
      "threadId" => thread,
      "runId" => nil,
      "projectId" => nil,
      "provider" => @provider,
      "itemType" => "dynamic_tool_call",
      "tool" => tool,
      "status" => "completed",
      "subagent" => true
    })

    snapshot()
  end

  # While the plugin is down its saved uses become unreadable.
  def corrupt_strays do
    path =
      Path.join([HalC2.Plugins.Host.data_dir("token-economizer"), "toolprune", "strays.json"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[{")
    snapshot()
  end

  # The thread's record comes to name its project, as every thread's but those made
  # before it kept one does.
  def thread_placed(thread) do
    commit(thread, [{"thread", thread, %{"s" => %{"projectId" => @project_id}}}])
    snapshot()
  end

  # It is imported back, with all it ran there.
  def thread_returned(thread) do
    commit(thread, [{"thread", thread, %{"s" => %{"movedTo" => nil}}}])
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
          unreadable: @provider in TokenEconomizer.prune_status(plugin)["unreadable"],
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
    do:
      Map.drop(
        prune,
        ~w(lastActivity seededThreads foldedRuns countedThreads liveThreads pending)
      )

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
        do: %{"type" => "subagent", "origin" => "provider_native", "subagentId" => "#{run}-s#{n}"},
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
