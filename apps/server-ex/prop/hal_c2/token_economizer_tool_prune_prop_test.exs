for file <- ~w(tool_prune_evidence),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerToolPrunePropTest do
  @moduledoc """
  Tool pruning's evidence (`ToolPrune.Evidence`) as a state machine: conversations
  fold in with the tools they loaded and used, the person applies and restores by
  name, `auto` applies what it held, threads start new conversations, the person
  raises or lowers the thresholds, and time passes, in any order. Whatever the
  order: a protected or ever-used tool is never off or proposed; a restored tool
  stays back until applied by name; a fold never turns anything off by itself;
  Codex demotes at most two packages per folded session, and proposes only the
  demoted, and only as a session is first counted; a use resets its tool's streak,
  and a segment whose record cannot show a tool's use leaves its evidence as it was;
  a thread's conversation counts as one session however many segments it folds,
  and as one live session once it is heard live, whether or not it was read back
  first; `auto` applies only what the live evidence still proposes, nothing under
  `propose`, nor while a turn is under way before the list has waited a day.

  The plugin's process and `shape_run/2` are covered by
  `features/plugins/token-economizer-tool-prune.feature`; upstream's cases are
  ported in `test/hal_c2/token_economizer_tool_prune_test.exs`.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer.ToolPrune.Evidence, as: Prune

  # Names commands draw on: candidates of both units, two protected tools, and one
  # that is no tool here at all.
  @names ~w(Workflow NotebookEdit CronCreate collaboration goals image_media
            Bash WebFetch NoSuchTool)

  property "the evidence keeps its laws in any order of folds, applies, restores and time",
    numtests: HalC2.Prop.numtests(200) do
    forall {unit, mode} <- {elements(["tool", "capability"]), elements(["auto", "propose"])} do
      forall cmds <- more_commands(3, commands(__MODULE__, initial_state())) do
        Process.put(:prune_run, start(unit, mode))
        {history, state, result} = run_commands(__MODULE__, cmds)

        (result == :ok)
        |> when_fail(
          IO.puts("""
          Unit: #{unit} mode: #{mode}
          History: #{inspect(history, pretty: true, limit: 60)}
          State: #{inspect(state, pretty: true)}
          Result: #{inspect(result, pretty: true)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  property "enough evidence only grows with more sessions or prompts, and high risk is stricter",
    numtests: HalC2.Prop.numtests(200) do
    forall {sessions, prompts} <- {integer(0, 40), integer(0, 120)} do
      cfg = Prune.config(%{})

      (not Prune.enough_evidence?(sessions, prompts, cfg) or
         (Prune.enough_evidence?(sessions + 1, prompts, cfg) and
            Prune.enough_evidence?(sessions, prompts + 1, cfg))) and
        (not Prune.enough_evidence?(sessions, prompts, cfg, true) or
           Prune.enough_evidence?(sessions, prompts, cfg))
    end
  end

  # What a hand-edited or older file may hold under the keys the evidence reads.
  @fields ~w(used kept off demoted streaks liveStreaks loadedSessions seededThreads foldedRuns
             countedThreads liveThreads sessions prompts importedSessions pending
             lastActivity items since run ordinal)

  property "any saved file reads as evidence of the right shape, and reads back the same",
    numtests: HalC2.Prop.numtests(200) do
    forall {unit, saved} <- {elements(["tool", "capability"]), map(elements(@fields), json())} do
      state = Prune.new(unit, saved)
      round = state |> Prune.dump() |> JSON.encode!() |> JSON.decode!()

      # Shaped as the folds read it: what folds in next folds like any other.
      folded =
        Prune.fold_segment(
          state,
          Prune.candidate_tools(unit),
          ["Workflow"],
          2,
          Prune.config(%{}),
          0,
          thread: "t1"
        )

      Prune.new(unit, round) == state and Enum.all?(Map.values(folded["streaks"]), &is_map/1)
    end
  end

  defp json, do: sized(size, json(min(size, 6)))

  defp json(0),
    do: oneof([exactly(nil), boolean(), integer(), float(), elements(@names), elements(@fields)])

  defp json(n) do
    frequency([
      {3, json(0)},
      {1, resize(3, list(json(div(n, 2))))},
      {1, resize(3, map(oneof([elements(@names), elements(@fields)]), json(div(n, 2))))}
    ])
  end

  # The evidence as the plugin runs it, with close thresholds so cases reach
  # proposals: 3 prompts over at least 2 sessions, or 3 sessions; no quiet wait.
  defp start(unit, mode) do
    cfg =
      Prune.config(%{
        "toolPrune" => mode,
        "toolPruneEvidence" => 3,
        "toolPruneMinSessions" => 2,
        "toolPruneSessions" => 3,
        "toolPruneQuietMinutes" => 0
      })

    %{prune: Prune.new(unit), cfg: cfg, now: 0}
  end

  def initial_state, do: %{folds: 0}

  def command(_state) do
    frequency([
      {6,
       {:call, __MODULE__, :fold,
        [
          integer(0, 4),
          resize(3, list(elements(@names))),
          elements([nil, "t1", "t2"]),
          boolean(),
          resize(2, list(elements(@names)))
        ]}},
      {1, {:call, __MODULE__, :converse, [elements(["t1", "t2"])]}},
      {1, {:call, __MODULE__, :settings, [elements([3, 30])]}},
      {2,
       {:call, __MODULE__, :apply,
        [elements([:proposal, :named]), resize(3, list(elements(@names)))]}},
      {2,
       {:call, __MODULE__, :restore,
        [elements([:all, :named]), resize(3, list(elements(@names)))]}},
      {2, {:call, __MODULE__, :pending, [boolean()]}},
      {2, {:call, __MODULE__, :note, [resize(3, list(elements(@names)))]}},
      {1, {:call, __MODULE__, :tick, [elements([1, 3_600, 90_000])]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(
        state,
        _result,
        {:call, _, :fold, [prompts, _used, _thread, _imported, _unrecorded]}
      ) do
    if prompts > 0, do: %{state | folds: state.folds + 1}, else: state
  end

  def next_state(state, _result, _call), do: state

  # --- the calls, on the real evidence the case holds -------------------------------

  defp run, do: Process.get(:prune_run)
  defp put_run(run), do: Process.put(:prune_run, run)

  # A segment of `thread`'s conversation (nil: one of its own) folds, heard live or
  # read back from the thread's history (`imported`), which may not record the uses
  # of some tools (`unrecorded`).
  def fold(prompts, used, thread, imported, unrecorded) do
    run = run()
    used = Enum.uniq(used)
    unrecorded = Enum.uniq(unrecorded)

    prune =
      run.prune
      |> Prune.activity(run.now)
      |> Prune.fold_segment(
        Prune.candidate_tools(run.prune["unit"]),
        used,
        prompts,
        run.cfg,
        run.now,
        thread: thread,
        imported: imported,
        unrecorded: unrecorded
      )

    put_run(%{run | prune: prune})

    %{
      before: run.prune,
      after: prune,
      prompts: prompts,
      used: used,
      thread: thread,
      imported: imported,
      unrecorded: unrecorded,
      cfg: run.cfg
    }
  end

  def converse(thread) do
    run = run()
    put_run(%{run | prune: Prune.new_conversation(run.prune, thread)})
    :ok
  end

  # The person sets the prompts and sessions it takes: low, or out of reach.
  def settings(evidence) do
    run = run()

    cfg =
      Prune.config(%{
        "toolPrune" => run.cfg["mode"],
        "toolPruneEvidence" => evidence,
        "toolPruneMinSessions" => 2,
        "toolPruneSessions" => evidence,
        "toolPruneQuietMinutes" => 0
      })

    put_run(%{run | cfg: cfg})
    :ok
  end

  def apply(which, names) do
    run = run()
    tools = if which == :proposal, do: nil, else: Enum.uniq(names)
    {prune, applied, refused} = Prune.apply_named(run.prune, run.cfg, tools)
    put_run(%{run | prune: prune})

    %{
      before: run.prune,
      after: prune,
      tools: tools,
      applied: applied,
      refused: refused,
      cfg: run.cfg
    }
  end

  def restore(which, names) do
    run = run()
    tools = if which == :all, do: nil, else: Enum.uniq(names)
    {prune, restored} = Prune.restore(run.prune, tools)
    put_run(%{run | prune: prune})
    %{before: run.prune, after: prune, restored: restored, cfg: run.cfg}
  end

  def pending(active) do
    run = run()
    {prune, applied} = Prune.apply_pending(run.prune, run.cfg, run.now, active)
    put_run(%{run | prune: prune})

    %{
      before: run.prune,
      after: prune,
      applied: applied,
      active: active,
      cfg: run.cfg,
      now: run.now
    }
  end

  # A use seen while a conversation is still under way, noted before its fold.
  def note(names) do
    run = run()
    used = Enum.uniq(names)
    prune = Prune.note_used(run.prune, used, run.cfg)
    put_run(%{run | prune: prune})
    %{before: run.prune, after: prune, used: used, cfg: run.cfg}
  end

  def tick(seconds) do
    run = run()
    put_run(%{run | now: run.now + seconds})
    :ok
  end

  # --- the laws ---------------------------------------------------------------------

  def postcondition(_state, {:call, _, :fold, _}, r) do
    demoted_growth = length(r.after["demoted"] -- r.before["demoted"])
    session = if r.prompts > 0 and r.thread not in r.before["countedThreads"], do: 1, else: 0

    live =
      if r.prompts > 0 and not r.imported and r.thread not in r.before["liveThreads"],
        do: 1,
        else: 0

    unused = Prune.candidate_tools(r.after["unit"]) -- r.used
    # What the segment cannot show the use of is no evidence it went unused.
    {unknown, unused} = Enum.split_with(unused, &(&1 in r.unrecorded))

    same = fn tool ->
      Enum.all?(
        ~w(streaks liveStreaks loadedSessions),
        &(r.after[&1][tool] == r.before[&1][tool])
      )
    end

    streak = &(&1["streaks"][&2] || %{"sessions" => 0})["sessions"]
    live_streak = &(&1["liveStreaks"][&2] || %{"sessions" => 0})["sessions"]

    # A fold turns nothing off by itself, at most heals something back.
    # Codex demotes at most two per session; other units never demote.
    # A use resets the streak and is remembered for good.
    Enum.all?(r.after["off"], &(&1 in r.before["off"])) and
      demoted_growth <= 2 * session and
      (r.after["unit"] == "capability" or r.after["demoted"] == r.before["demoted"]) and
      Enum.all?(r.used, fn tool ->
        tool in r.after["used"] and
          (tool not in Prune.candidate_tools(r.after["unit"]) or
             (r.after["streaks"][tool] || %{"sessions" => 0})["sessions"] == 0)
      end) and
      r.after["sessions"] - r.before["sessions"] == session and
      Enum.all?(unused, &(streak.(r.after, &1) - streak.(r.before, &1) == session)) and
      Enum.all?(unused, &(live_streak.(r.after, &1) - live_streak.(r.before, &1) == live)) and
      Enum.all?(unknown, same) and
      lawful?(r.after, r.cfg)
  end

  def postcondition(_state, {:call, _, :apply, _}, r) do
    # Never a protected, used, or unknown name, even asked for by name; what was
    # asked for and not applied was refused.
    Enum.all?(r.applied, fn tool ->
      tool in Prune.candidate_tools(r.after["unit"]) and
        not Prune.protected?(tool, r.cfg) and tool not in r.after["used"] and
        tool in r.after["off"]
    end) and
      (r.tools == nil or Enum.sort(r.applied ++ r.refused) == Enum.sort(r.tools)) and
      lawful?(r.after, r.cfg)
  end

  def postcondition(_state, {:call, _, :restore, _}, r) do
    # Only what was off comes back, and it is kept: off neither list until named.
    Enum.all?(r.restored, &(&1 in r.before["off"] and &1 not in r.after["off"])) and
      Enum.all?(r.restored, &(&1 in r.after["kept"])) and
      Enum.all?(r.restored, &(&1 not in Prune.proposal(r.after, r.cfg))) and
      lawful?(r.after, r.cfg)
  end

  def postcondition(_state, {:call, _, :pending, _}, r) do
    (r.cfg["mode"] == "auto" or r.applied == []) and
      Enum.all?(r.applied, &(&1 in Prune.proposal(r.before, r.cfg))) and
      Enum.all?(r.applied, &live_enough?(r.before, &1, r.cfg)) and
      (not r.active or r.applied == [] or
         r.now - ((r.before["pending"] || %{})["since"] || r.now) >= 86_400) and
      Enum.all?(r.applied, &(&1 in r.after["off"])) and
      Enum.sort(r.after["off"]) == Enum.sort(Enum.uniq(r.before["off"] ++ r.applied)) and
      lawful?(r.after, r.cfg)
  end

  def postcondition(_state, {:call, _, :note, _}, r) do
    # Noted at once: remembered as used, and off at most what was off before.
    Enum.all?(r.used, &(&1 in r.after["used"] and &1 not in r.after["off"])) and
      Enum.all?(r.after["off"], &(&1 in r.before["off"])) and
      lawful?(r.after, r.cfg)
  end

  def postcondition(_state, {:call, _, call, _}, :ok) when call in [:tick, :converse, :settings],
    do: true

  defp live_enough?(prune, tool, cfg) do
    streak = prune["liveStreaks"][tool] || %{"sessions" => 0, "prompts" => 0}

    Prune.enough_evidence?(
      streak["sessions"],
      streak["prompts"],
      cfg,
      Prune.high_risk?(tool)
    )
  end

  # What holds of any state the evidence reaches: nothing protected or used is off
  # or proposed, nothing kept is proposed, and Codex proposes only the demoted.
  defp lawful?(prune, cfg) do
    denied = Prune.denied(prune, cfg)
    proposed = Prune.proposal(prune, cfg)

    Enum.all?(denied ++ proposed, fn tool ->
      not Prune.protected?(tool, cfg) and tool not in prune["used"]
    end) and
      Enum.all?(proposed, &(&1 not in prune["kept"] and &1 not in prune["off"])) and
      (prune["unit"] != "capability" or Enum.all?(proposed, &(&1 in prune["demoted"])))
  end
end
