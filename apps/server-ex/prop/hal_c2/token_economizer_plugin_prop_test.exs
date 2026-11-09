for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge tool_prune_evidence token_economizer),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerPluginPropTest do
  @moduledoc """
  A state machine model of TokenEconomizer's process (`HalC2Plugins.TokenEconomizer`):
  the turns of two threads of one project heard through the feed, which may say it
  missed events, the mode changed between redirecting, watching and off, the process
  restarted while its feed still holds events, and the answers of its judge jobs and
  deliveries reaching it late, in any order, or never.

  The case drives the process's callbacks itself. Its tasks run for real and, with no
  plugin host to grant them anything, end at once: what each sent and its end are held,
  and reach the process when a command delivers them, with the judge's verdict (stuck
  or productive) or the delivery's outcome (taken or refused) the command chooses.
  After every step:

  - turned off, it watches no turn and has no task out;
  - watching, it has no delivery out and no redirect on its way;
  - it watches exactly the turns under way that it heard start while on, by their run;
  - a judge job is out only for a thread with a turn under way and not offered its
    stop, at most one for each;
  - no run gets more redirects than the budget, nor more than one stop offer;
  - a turn teaches the project's envelope only when it ended completed, made calls and
    was heard whole, never when the next turn's start closes it, and a subagent's calls
    are not its own; one heard whole that
    completed with nothing but passing checks does. A turn is heard whole unless it was
    under way when the feed said it missed events, or one of its events came in the
    window that report opens: the reported event and those the feed had waiting, heard
    while on or off. A restart opens such a window over every event the feed still
    holds and the one it may be blocked delivering.

  `prop/hal_c2/token_economizer_prop_test.exs` runs one turn's guard;
  `proof/hal_c2/token_economizer_loop_guard_proof_test.exs` explores the turns, the
  feed and the tasks over every interleaving, up to its bounds.
  """
  # The plugin keeps its envelopes under the MC's home, which a scratch home sets for
  # the whole VM.
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer
  alias HalC2Plugins.TokenEconomizer.LoopGuard.Envelope

  @threads ~w(a b)
  @project {"p", "claudeAgent"}
  # The lengths of the project's turns that ended green, enough for an envelope.
  @learned [3, 3, 4, 4, 5]

  property "the plugin keeps its laws over two threads, missed events, restarts, mode changes and late answers",
    numtests: HalC2.Prop.numtests(1000) do
    forall budget <- integer(0, 2) do
      forall cmds <- more_commands(8, commands(__MODULE__, initial_state(budget))) do
        {history, state, result, reached} = run_case(budget, cmds)

        (result == :ok)
        |> when_fail(
          IO.puts("""
          Budget: #{budget}
          History: #{inspect(history, pretty: true, limit: 80)}
          State: #{inspect(state, pretty: true)}
          Result: #{inspect(result, pretty: true)}
          """)
        )
        |> aggregate(command_names(cmds))
        |> collect(reached)
      end
    end
  end

  test "a case leaves the MC's home and environment as it found them" do
    before = {Application.fetch_env(:hal_c2, :home), System.fetch_env("GIT_CEILING_DIRECTORIES")}
    {_, _, :ok, :watched} = run_case(0, [])

    assert {Application.fetch_env(:hal_c2, :home), System.fetch_env("GIT_CEILING_DIRECTORIES")} ==
             before
  end

  defp run_case(budget, cmds) do
    open_case(budget)

    try do
      {history, state, result} = run_commands(__MODULE__, cmds)
      {history, state, result, close_case()}
    after
      HalC2.Prop.restore_env()
    end
  end

  defp open_case(budget) do
    HalC2.Prop.scratch_home("token-economizer")

    # Where a restarted process finds its feed (`restart/3`).
    case Registry.start_link(keys: :unique, name: HalC2.Plugins.Hooks) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    path = TokenEconomizer.envelope_path(@project)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"level" => "default", "resolved_turns" => @learned}))
    {:ok, plugin} = TokenEconomizer.init(settings("nudge", budget))
    Process.put(:plugin, plugin)
    Process.put(:held, [])
  end

  # What the case reached, for `PROPCHECK_VERBOSE=1`.
  defp close_case do
    plugin = Process.delete(:plugin)
    Process.delete(:held)
    stop(plugin)

    cond do
      plugin.stats["aborts"] > 0 -> :offered_a_stop
      plugin.stats["nudges"] > 0 -> :redirected
      plugin.stats["judgeCalls"] > 0 -> :judged
      learned(plugin) > length(@learned) -> :taught
      true -> :watched
    end
  end

  defp stop(plugin) do
    ref = Process.monitor(plugin.sup)
    Process.unlink(plugin.sup)
    Process.exit(plugin.sup, :shutdown)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    flush()
  end

  defp flush do
    receive do
      {kind, _, _, _, _} when kind in [:verdict, :delivered, :DOWN] -> flush()
    after
      0 -> :ok
    end
  end

  # Thresholds a person may pin, low enough for a few calls to make a loop.
  defp settings(mode, budget),
    do: %{
      "loopGuard" => mode,
      "loopGuardNudges" => budget,
      "loopGuardThresholds" => %{
        "min_turns" => 4,
        "gate_min_turns" => 4,
        "error_outputs" => 2,
        "gate_error_outputs" => 2
      }
    }

  # --- the model --------------------------------------------------------------------------

  # `open`: thread => %{run, partial, kinds}, the turns under way the plugin heard start
  # while on. `missing`: the events still to hear that the feed had waiting when it said
  # it missed some; the turns they belong to are partial.
  def initial_state(budget \\ 1),
    do: %{budget: budget, mode: "nudge", runs: 0, open: %{}, missing: 0}

  def command(state) do
    open = Map.keys(state.open)
    # Mostly a thread with a turn under way, now and then an event for another run.
    thread =
      if open == [],
        do: elements(@threads),
        else: frequency([{6, elements(open)}, {1, elements(@threads)}])

    frequency([
      {if(open == [], do: 6, else: 1),
       {:call, __MODULE__, :start, [elements(@threads), "r#{state.runs + 1}", dropped()]}},
      {8,
       let t <- thread do
         {:call, __MODULE__, :item, [t, run_of(state, t), kind(), dropped()]}
       end},
      {1,
       let t <- thread do
         {:call, __MODULE__, :finish,
          [t, run_of(state, t), elements(~w(completed interrupted)), dropped()]}
       end},
      {5, {:call, __MODULE__, :answer, [integer(0, 3), frequency([{2, true}, {1, false}])]}},
      {1,
       {:call, __MODULE__, :mode,
        [frequency([{2, "nudge"}, {2, "watch"}, {1, "off"}]), state.budget]}},
      {1, {:call, __MODULE__, :restart, [state.mode, state.budget, integer(0, 3)]}}
    ])
  end

  # false, or the events the feed had waiting when it said it missed some.
  defp dropped, do: frequency([{6, false}, {1, integer(0, 2)}])
  # "sub": a failing call of a subagent the turn runs, which is no call of the turn's.
  defp kind, do: frequency([{5, "fail"}, {3, "edit"}, {2, "pass"}, {1, "sub"}])

  defp run_of(state, t) do
    case state.open[t] do
      %{run: run} -> run
      nil -> "r0"
    end
  end

  def precondition(state, {:call, _, :start, [_, run, _]}), do: run == "r#{state.runs + 1}"

  def precondition(state, {:call, _, name, [t, run | _]}) when name in [:item, :finish],
    do: run == "r0" or match?(%{run: ^run}, state.open[t])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :start, [t, run, dropped]}) do
    state = %{state | runs: state.runs + 1}
    heard(state, t, dropped, &put_in(&1.open[t], %{run: run, partial: false, kinds: []}))
  end

  def next_state(state, _result, {:call, _, :item, [t, run, kind, dropped]}) do
    heard(state, t, dropped, fn state ->
      case state.open[t] do
        %{run: ^run} when kind != "sub" -> update_in(state.open[t].kinds, &(&1 ++ [kind]))
        _ -> state
      end
    end)
  end

  def next_state(state, _result, {:call, _, :finish, [t, run, _, dropped]}) do
    heard(state, t, dropped, fn state ->
      case state.open[t] do
        %{run: ^run} -> %{state | open: Map.delete(state.open, t)}
        _ -> state
      end
    end)
  end

  def next_state(state, _result, {:call, _, :mode, [mode, _]}),
    do: %{state | mode: mode, open: if(mode == "off", do: %{}, else: state.open)}

  # The process restarted, its feed holding `held` events and maybe blocked delivering
  # one more: it watches no turn, and each of those may have been sent before ones it
  # missed.
  def next_state(state, _result, {:call, _, :restart, [_, _, held]}),
    do: %{state | open: %{}, missing: held + 1}

  def next_state(state, _result, _call), do: state

  # An event of thread `t`: a report of missed events marks the turns under way partial
  # and opens a window over the reported event and those waiting behind it; `hear`
  # applies the event, only while on; each event in the window marks its thread's turn
  # partial. Turned off, the process watches no turn, but the window still runs over
  # the events it hears, so a turn that starts in it once on again is partial.
  defp heard(state, t, dropped, hear) do
    state =
      if dropped == false,
        do: state,
        else: %{
          state
          | open: Map.new(state.open, fn {t, turn} -> {t, %{turn | partial: true}} end),
            missing: max(state.missing, dropped + 1)
        }

    state = if state.mode == "off", do: state, else: hear.(state)

    cond do
      state.missing == 0 -> state
      state.open[t] -> %{put_in(state.open[t].partial, true) | missing: state.missing - 1}
      true -> %{state | missing: state.missing - 1}
    end
  end

  def postcondition(state, {:call, _, name, args} = call, seen) do
    after_ = next_state(state, seen, call)
    tasks = Enum.frequencies(seen.tasks)
    judged = for {{t, :judge}, n} <- tasks, do: {t, n}

    laws = [
      off: after_.mode != "off" or (seen.turns == %{} and seen.tasks == []),
      watch:
        after_.mode != "watch" or
          (not Enum.any?(seen.tasks, &match?({_, :delivery}, &1)) and seen.redirecting == []),
      turns: seen.turns == Map.new(after_.open, fn {t, turn} -> {t, turn.run} end),
      judge:
        Enum.all?(judged, fn {t, n} ->
          n == 1 and Map.has_key?(seen.turns, t) and t not in seen.offered
        end),
      budget:
        Enum.all?(seen.acts, fn {{_, _, action}, n} ->
          if action == "nudge", do: n <= state.budget, else: n <= 1
        end),
      teaches: teaches?(state, name, args, seen.taught)
    ]

    case for {law, false} <- laws, do: law do
      [] -> true
      broken -> {:broken, broken, seen}
    end
  end

  defp teaches?(state, :finish, [t, run, status, dropped], taught) do
    case state.open[t] do
      %{run: ^run} = turn when state.mode != "off" ->
        whole = not turn.partial and dropped == false
        green = whole and status == "completed" and turn.kinds != []

        (not taught or green) and
          (taught or not (green and Enum.all?(turn.kinds, &(&1 == "pass"))))

      _ ->
        not taught
    end
  end

  defp teaches?(_state, _name, _args, taught), do: not taught

  # --- the commands -------------------------------------------------------------------------

  def start(t, run, dropped),
    do:
      observe(%{"type" => "turn.started", "threadId" => t, "runId" => run} |> project(), dropped)

  def item(t, run, kind, dropped),
    do:
      observe(
        Map.merge(tool(kind), %{"type" => "turn.item", "threadId" => t, "runId" => run}),
        dropped
      )

  def finish(t, run, status, dropped),
    do:
      observe(
        %{"type" => "turn.finished", "threadId" => t, "runId" => run, "status" => status},
        dropped
      )

  def mode(mode, budget) do
    {:reply, :ok, plugin} =
      TokenEconomizer.handle_call({:settings, settings(mode, budget)}, nil, Process.get(:plugin))

    settle(plugin, false)
  end

  # The process goes down with its tasks and starts again in mode `mode`, while a feed
  # that kept running holds `held` events.
  def restart(mode, budget, held) do
    stop(Process.get(:plugin))
    Process.put(:held, [])
    case_ = self()

    feed =
      spawn(fn ->
        Registry.register(HalC2.Plugins.Hooks, {:observe, "token-economizer"}, %{
          id: "token-economizer",
          dropped: :counters.new(1, [])
        })

        send(case_, :registered)
        receive do: (:stop -> :ok)
      end)

    receive do: (:registered -> :ok)
    for i <- 1..held//1, do: send(feed, {:queued, i})
    {:ok, plugin} = TokenEconomizer.init(settings(mode, budget))
    send(feed, :stop)
    settle(plugin, false)
  end

  # Delivers the next message of the `n`th newest task held, with the verdict or the outcome
  # `yes` chooses: stuck, or a redirect taken.
  def answer(n, yes) do
    plugin = Process.get(:plugin)

    case Process.get(:held) do
      [] ->
        settle(plugin, false)

      held ->
        i = length(held) - 1 - rem(n, length(held))
        [message | rest] = Enum.at(held, i)

        Process.put(
          :held,
          if(rest == [], do: List.delete_at(held, i), else: List.replace_at(held, i, rest))
        )

        {:noreply, plugin} = TokenEconomizer.handle_info(outcome(message, yes), plugin)
        settle(plugin, false)
    end
  end

  defp outcome({:verdict, t, run, job, _}, yes) do
    verdict =
      if yes,
        do: %{"stuck" => true, "confidence" => 0.95, "reason" => "loop", "_nudge" => "Step back."},
        else: %{"stuck" => false, "confidence" => 0.9, "reason" => "progress"}

    {:verdict, t, run, job, Map.put(verdict, "_tokens", 5)}
  end

  defp outcome({:delivered, t, run, entry, _}, yes),
    do: {:delivered, t, run, entry, if(yes, do: {:ok, %{}}, else: {:error, "refused"})}

  defp outcome(down, _), do: down

  defp project(event), do: Map.merge(event, %{"projectId" => "p", "provider" => "claudeAgent"})

  defp tool("fail"),
    do: %{
      "itemType" => "command_execution",
      "status" => "failed",
      "input" => "pytest -q",
      "output" => "FAILED tests/test_a.py::test_a - AssertionError: assert 1 == 2",
      "exitCode" => 1
    }

  defp tool("pass"),
    do: %{
      "itemType" => "command_execution",
      "status" => "completed",
      "input" => "pytest -q",
      "output" => "3 passed in 0.10s",
      "exitCode" => 0
    }

  defp tool("sub"), do: Map.put(tool("fail"), "subagent", true)

  defp tool("edit"),
    do: %{"itemType" => "file_change", "status" => "completed", "path" => "/r/a.py"}

  defp observe(event, dropped) do
    plugin = Process.get(:plugin)
    before = learned(plugin)

    event =
      if dropped == false,
        do: event,
        else: Map.merge(event, %{"dropped" => 1, "waiting" => dropped})

    {:reply, :ok, plugin} = TokenEconomizer.handle_call({:observe, event}, nil, plugin)
    settle(plugin, learned(plugin, before) > before)
  end

  # How many turns the project's envelope has learned: in the plugin, or in its file.
  defp learned(plugin, saved \\ nil) do
    case plugin.trackers[@project] do
      nil ->
        saved ||
          @project
          |> TokenEconomizer.envelope_path()
          |> File.read!()
          |> JSON.decode!()
          |> Map.fetch!("resolved_turns")
          |> length()

      tracker ->
        tracker |> Envelope.dump() |> Map.fetch!("resolved_turns") |> length()
    end
  end

  # What the plugin shows after a step, then its new tasks' messages and ends, held: a
  # task sends one message, then ends. A task stopped in the step it started may have
  # sent its message first.
  defp settle(plugin, taught) do
    held = Process.get(:held)

    known =
      MapSet.new(
        for [{:DOWN, _, :process, pid, _} | _] <- Enum.map(held, &Enum.take(&1, -1)), do: pid
      )

    fresh =
      for {pid, {t, kind}} <- plugin.tasks, not MapSet.member?(known, pid) do
        # A judge's job is the one its turn has out: a job stopped as it started, in this
        # step, may have answered for the thread too.
        job = get_in(plugin.turns, [t, :guard, :judge_pending, "id"])

        message =
          receive do
            {:verdict, ^t, _, id, _} = message when kind == :judge and id in [job, nil] ->
              [message]

            {:delivered, ^t, _, _, _} = message when kind == :delivery ->
              [message]
          after
            5_000 -> raise "task #{inspect(pid)} of #{t} sent nothing"
          end

        receive do
          {:DOWN, _, :process, ^pid, _} = down -> message ++ [down]
        after
          5_000 -> raise "task #{inspect(pid)} of #{t} did not end"
        end
      end

    Process.put(:held, held ++ fresh ++ strays())
    Process.put(:plugin, plugin)
    shown(plugin, taught)
  end

  defp strays do
    receive do
      {kind, _, _, _, _} = message when kind in [:verdict, :delivered, :DOWN] ->
        [[message] | strays()]
    after
      0 -> []
    end
  end

  defp shown(plugin, taught) do
    %{
      turns: Map.new(plugin.turns, fn {t, turn} -> {t, turn.run} end),
      tasks: Map.values(plugin.tasks),
      redirecting: for({t, %{guard: %{redirecting: true}}} <- plugin.turns, do: t),
      offered: for({t, %{guard: %{abort_delivered: true}}} <- plugin.turns, do: t),
      acts: Enum.frequencies_by(plugin.recent, &{&1["threadId"], &1["runId"], &1["action"]}),
      taught: taught
    }
  end
end
