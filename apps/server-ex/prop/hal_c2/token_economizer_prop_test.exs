for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerPropTest do
  @moduledoc """
  TokenEconomizer's loop guard (`plugins/token-economizer/mc`), its pure parts:

  - a state machine of one turn's guard (`LoopGuard.Turn`), fed tool calls, judge
    verdicts, the clock and whether a redirect reached the agent, in any order, as the
    plugin feeds it. Whatever the order: a project with no envelope is never acted on
    and never judged; no more redirects than the budget; the stop offer comes only once
    the redirects are spent, at most once, and nothing is decided after it; nothing is
    decided or judged while a redirect is on its way; only a redirect that landed starts
    a fresh segment, and one refused leaves the segment as it was; a judge job starts
    only when none is out, or the one out has gone stale, and asks for a redirect only
    while one can still be sent; a verdict for a job that is
    not out changes nothing but the spend; every call is counted;
  - what the envelope learns: from any run of turns, exactly the ones that ended
    green, no envelope before enough of them, and the signal thresholds never below
    the level's; an edit that failed does not make a failing check look old;
  - what the judge is shown of an edit through the shell: whatever writes the file,
    behind whatever wrapper, inside whatever list, group or nested shell, the file is
    counted and what was written into it is never shown.

  The plugin's process, the MC's turns and the delivery of redirects and notices are
  covered by `features/plugins/token-economizer-loop-guard.feature`.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, Rules, ShellEdits, State, Turn}

  @stale 300

  # --- one turn, as a state machine ------------------------------------------------------

  property "a turn's guard keeps its laws in any order of calls, verdicts and time",
    numtests: HalC2.Prop.numtests(200) do
    forall {samples, budget} <- {learned(), integer(0, 2)} do
      forall cmds <- more_commands(4, commands(__MODULE__, initial_state(samples, budget))) do
        Process.put(:guard, start(samples, budget))
        {history, state, result} = run_commands(__MODULE__, cmds)
        run = Process.get(:guard)

        (result == :ok)
        |> when_fail(
          IO.puts("""
          Samples: #{inspect(samples)} budget: #{budget}
          History: #{inspect(history, pretty: true, limit: 60)}
          State: #{inspect(state, pretty: true)}
          Result: #{inspect(result, pretty: true)}
          """)
        )
        |> aggregate(command_names(cmds))
        |> collect(outcome(run))
      end
    end
  end

  # The lengths of a project's turns that ended green: mostly enough for an envelope.
  defp learned do
    let n <- frequency([{1, integer(0, 4)}, {3, integer(5, 7)}]) do
      vector(n, integer(3, 6))
    end
  end

  # What a case reached, for `PROPCHECK_VERBOSE=1`.
  defp outcome(run) do
    cond do
      run.envelope == nil -> :unlearned
      run.stops > 0 -> :offered_a_stop
      run.nudges > 0 -> :redirected
      run.jobs > 0 -> :judged
      true -> :watched
    end
  end

  # The guard as the plugin runs it: the project's envelope, its thresholds with the
  # judge woken only by trouble, the budget, and a ledger of what it decided.
  defp start(samples, budget) do
    tracker = Envelope.new("default", %{}, %{"resolved_turns" => samples})
    thr = Envelope.turn_thresholds(tracker, %{})

    thr =
      Map.merge(thr, %{
        "gate_over_envelope" => false,
        "gate_min_turns" => max(thr["gate_min_turns"], thr["min_turns"])
      })

    %{
      guard: Turn.new("t:r"),
      envelope: Envelope.envelope(tracker),
      thr: thr,
      budget: budget,
      now: 0,
      nudges: 0,
      stops: 0,
      jobs: 0,
      # The judge job out, `{id, started at}`, until its verdict is delivered or a
      # redirect that landed starts a new segment.
      out: nil
    }
  end

  def initial_state(samples \\ [], budget \\ 1),
    do: %{learned: length(samples) >= 5, budget: budget, calls: 0}

  def command(_state) do
    frequency([
      # Mostly the loop the guard is for, with now and then a sign of progress.
      {8, {:call, __MODULE__, :tools, [resize(6, non_empty(list(kind())))]}},
      {1,
       {:call, __MODULE__, :verdict, [elements([:out, :other]), boolean(), elements([0.4, 0.95])]}},
      {1, {:call, __MODULE__, :tick, [elements([0, 60, @stale])]}},
      {1, {:call, __MODULE__, :landed, [boolean()]}}
    ])
  end

  # Mostly the loop the guard is for, with now and then a sign of progress.
  defp kind,
    do: frequency([{4, "edit"}, {5, "fail"}, {1, "pass"}, {1, "read"}, {1, "bad_edit"}])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :tools, [kinds]}),
    do: %{state | calls: state.calls + length(kinds)}

  def next_state(state, _result, _call), do: state

  # Tool calls folded one by one as the plugin folds them; what each did.
  def tools(kinds), do: Enum.map(kinds, &tool/1)

  # A nudge's redirect is sent (whether it lands is `landed/1`), a job is put out.
  defp tool(kind) do
    run = Process.get(:guard)
    {name, args, result, code} = call(kind)

    {guard, decision, job} =
      Turn.fold(run.guard, name, args, result, code,
        envelope: run.envelope,
        thr: run.thr,
        judge: run.envelope != nil,
        nudge_budget: run.budget,
        now: run.now
      )

    {text, guard} =
      case decision do
        {:nudge, _} ->
          {text, guard} = Turn.nudge_body(guard)
          {text, Turn.redirect(guard)}

        _ ->
          {nil, guard}
      end

    after_run = %{
      run
      | guard: guard,
        nudges: run.nudges + if(match?({:nudge, _}, decision), do: 1, else: 0),
        stops: run.stops + if(match?({:abort, _}, decision), do: 1, else: 0),
        jobs: run.jobs + if(job, do: 1, else: 0),
        out: if(job, do: {job["id"], run.now}, else: run.out)
    }

    Process.put(:guard, after_run)
    %{before: run, after: after_run, decision: decision, job: job, text: text}
  end

  def verdict(which, stuck, confidence) do
    run = Process.get(:guard)

    id =
      case {which, run.out} do
        {:out, {id, _}} -> id
        _ -> "t:r:9:9"
      end

    verdict = %{"stuck" => stuck, "confidence" => confidence, "reason" => "r", "_tokens" => 7}
    guard = Turn.verdict(run.guard, id, verdict)
    out = if run.out != nil and elem(run.out, 0) == id, do: nil, else: run.out
    after_run = %{run | guard: guard, out: out}
    Process.put(:guard, after_run)
    %{before: run, after: after_run, id: id}
  end

  # The redirect on its way reached the agent, or was refused; nothing when none is.
  def landed(landed) do
    run = Process.get(:guard)

    after_run =
      if run.guard.redirecting,
        do: %{
          run
          | guard: Turn.redirected(run.guard, landed),
            out: if(landed, do: nil, else: run.out)
        },
        else: run

    Process.put(:guard, after_run)
    %{before: run, after: after_run, landed: landed}
  end

  def tick(seconds) do
    run = Process.get(:guard)
    Process.put(:guard, %{run | now: run.now + seconds})
    :ok
  end

  defp call("edit"), do: {"Edit", %{"path" => "a.py"}, "", nil}

  defp call("fail"),
    do:
      {"Bash", %{"command" => "pytest -q test_a.py"},
       "FAILED test_a.py::test_a\n1 failed in 0.02s", 1}

  defp call("pass"), do: {"Bash", %{"command" => "pytest -q test_a.py"}, "1 passed in 0.02s", 0}
  defp call("read"), do: {"Bash", %{"command" => "cat a.py"}, "x = 1", 0}
  defp call("bad_edit"), do: {"Edit", %{"path" => "a.py"}, "String to replace not found", 1}

  def postcondition(state, {:call, _, :tools, _}, steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.all?(fn {step, i} -> lawful?(state, step, state.calls + i) end)
  end

  def postcondition(_state, {:call, _, :verdict, _}, %{before: before, after: run, id: id}) do
    out? = before.out != nil and elem(before.out, 0) == id
    unchanged = %{run.guard | judge_tokens: before.guard.judge_tokens}

    # A verdict is always paid for; one for a job not out is otherwise ignored.
    run.guard.judge_tokens == before.guard.judge_tokens + 7 and
      (out? or unchanged == before.guard)
  end

  def postcondition(_state, {:call, _, :landed, _}, %{before: before, after: run} = r) do
    g = before.guard

    cond do
      not g.redirecting ->
        run == before

      # Landed: the next segment starts afresh, and the old one's job is forgotten.
      r.landed ->
        not run.guard.redirecting and run.guard.segment == g.segment + 1 and
          run.guard.redirects == g.redirects + 1 and run.guard.st.turns == 0 and
          run.guard.judge_pending == nil and run.guard.nudges_done == g.nudges_done

      # Refused: the segment goes on as it was.
      true ->
        run.guard == %{g | redirecting: false}
    end
  end

  def postcondition(_state, {:call, _, :tick, _}, :ok), do: true

  defp lawful?(state, %{before: before, after: run} = r, calls) do
    acted = r.decision != nil

    # Never acted on, or judged, before the project has an envelope.
    # The budget, then one stop offer, then nothing.
    # A redirect has words in it.
    # One judge job out at a time, unless the one out went stale.
    # A job asks for a redirect to be written only while one can still be sent.
    # Nothing decided or judged while a redirect is on its way.
    (state.learned or (not acted and r.job == nil)) and
      (not before.guard.redirecting or (not acted and r.job == nil)) and
      run.nudges <= state.budget and
      run.stops <= 1 and
      (not match?({:abort, _}, r.decision) or before.nudges == state.budget) and
      (before.stops == 0 or not acted) and
      (r.text == nil or String.trim(r.text) != "") and
      (r.job == nil or before.out == nil or before.now - elem(before.out, 1) >= @stale) and
      (r.job == nil or r.job["redirect"] == before.guard.nudges_done < state.budget) and
      run.guard.cum_turns == calls
  end

  # --- what the envelope learns ----------------------------------------------------------

  property "the envelope learns exactly the turns that ended green",
    numtests: HalC2.Prop.numtests(200) do
    forall turns <-
             resize(
               12,
               list(
                 {integer(1, 6), elements(~w(green failing failed_edit stopped guard_stopped))}
               )
             ) do
      tracker =
        Enum.reduce(turns, Envelope.new(), fn {calls, outcome}, tracker ->
          Envelope.record_turn(tracker, guard(calls, outcome), outcome != "stopped")
        end)

      green = for {calls, "green"} <- turns, do: calls
      base = Rules.scaled_thresholds("default")
      thr = Envelope.turn_thresholds(tracker)

      (tracker.resolved_turns == green and
         Envelope.envelope(tracker) == nil == length(green) < base["envelope_min_samples"] and
         Enum.all?(
           ~w(edit_churn distinct_edit_files error_outputs gate_error_outputs stagnation),
           &(thr[&1] >= base[&1])
         ))
      |> when_fail(
        IO.puts("Turns: #{inspect(turns)}\nLearned: #{inspect(tracker.resolved_turns)}")
      )
    end
  end

  # A turn of `calls` tool calls: it read and checked green, or its last check after an
  # edit failed (and an edit after that did not apply), or the agent did not stop on its
  # own, or the guard stopped it.
  defp guard(calls, outcome) do
    kinds =
      case outcome do
        "failing" -> List.duplicate("read", calls - 1) ++ ["edit", "fail"]
        "failed_edit" -> List.duplicate("read", calls - 1) ++ ["edit", "fail", "bad_edit"]
        _ -> List.duplicate("pass", calls)
      end

    guard =
      Enum.reduce(kinds, Turn.new("t:r"), fn kind, g ->
        {name, args, result, code} = call(kind)
        {g, _, _} = Turn.fold(g, name, args, result, code)
        g
      end)

    if outcome == "guard_stopped", do: %{guard | aborted: true}, else: guard
  end

  # --- what the judge is shown of an edit through the shell --------------------------------

  property "an edit through the shell is counted and its words never shown, however run",
    numtests: HalC2.Prop.numtests(300) do
    forall cmd <- shell_edit() do
      st = State.update(State.new(), "Bash", %{"command" => cmd}, "", false)
      shown = State.recent_digest(st)

      ("a.py" in ShellEdits.targets(cmd) and not String.contains?(shown, "SECRET"))
      |> when_fail(
        IO.puts("""
        Command: #{inspect(cmd)}
        Targets: #{inspect(ShellEdits.targets(cmd))}
        Shown: #{shown}
        """)
      )
    end
  end

  # A command that writes SECRET into a.py: a writer, behind a wrapper, on a path spelt
  # one of the ways a path is, inside a carrier (a list, a group, a nested shell, a line
  # continued).
  defp shell_edit do
    let {{writer, nestable}, wrapper, path, carrier} <-
          {elements(writers()),
           elements([
             "",
             "sudo ",
             "sudo -u me ",
             "env X=1 ",
             "command ",
             "timeout 10 ",
             "nice -n 5 ",
             "X=1 "
           ]), elements(["a.py", "./src/a.py", "\"src/a.py\"", "'a.py'", "src/a'.py'"]),
           elements(
             ~w(alone and_before semi_after subshell braces pipe_from continued nested eval)a
           )} do
      run = String.replace(wrapper <> writer, "@P", path)
      carry(carrier, run, nestable and not String.contains?(path, "'"))
    end
  end

  # Writers, and whether one can go inside a quoted script (it has no quotes or heredoc).
  defp writers do
    [
      {"echo SECRET > @P", true},
      {"printf SECRET >> @P", true},
      {"echo SECRET >| @P", true},
      {"echo SECRET &> @P", true},
      {"echo SECRET 1> @P", true},
      {">@P echo SECRET", true},
      {"echo SECRET | tee -a @P", true},
      {"tee @P <<< SECRET", true},
      {"dd of=@P <<< SECRET", true},
      {"sed -i s/x/SECRET/ @P", true},
      {"sed -i.bak -e s/x/SECRET/ @P", true},
      {"sed --in-place -Ee's/x/SECRET/' @P", false},
      {"sed -i -e'1iSECRET;SECRET' @P", false},
      {"perl -pi -e 's/x/SECRET/' @P", false},
      {"printf 'SECRET\n' > @P", false},
      {"printf $'SECRET\\n' > @P", false},
      {"cat > @P <<'EOF'\nSECRET\nEOF", false},
      {"cat <<-EOF > @P\n\tSECRET\n\tEOF", false}
    ]
  end

  defp carry(:alone, run, _), do: run
  defp carry(:and_before, run, _), do: "cd x && " <> run
  defp carry(:semi_after, run, _), do: if(heredoc?(run), do: run, else: run <> "; ls")
  defp carry(:subshell, run, _), do: if(heredoc?(run), do: run, else: "(" <> run <> ")")
  defp carry(:braces, run, _), do: if(heredoc?(run), do: run, else: "{ " <> run <> "; }")
  defp carry(:pipe_from, run, _), do: "true | " <> run
  defp carry(:continued, run, _), do: String.replace(run, " ", " \\\n  ", global: false)
  defp carry(:nested, run, true), do: "cd x && bash -c '" <> run <> "'"
  defp carry(:eval, run, true), do: "eval '" <> run <> "'"
  defp carry(_, run, false), do: run

  defp heredoc?(run), do: String.contains?(run, "\n")
end
