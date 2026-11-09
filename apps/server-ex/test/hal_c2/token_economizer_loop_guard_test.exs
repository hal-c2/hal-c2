# SPDX-License-Identifier: Apache-2.0
# Ported in part from tests/test_loopguard_productive_turns.py and
# tests/test_config_integer_thresholds.py (microsoft/TokenEconomizer@cb42207e3e09).

for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge micro_skills_lifecycle micro_skills_observe micro_skills_envfacts micro_skills_history micro_skills_distiller token_economizer),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerLoopGuardTest do
  @moduledoc """
  The TokenEconomizer plugin's loop guard (`plugins/token-economizer/mc`), as plain
  functions: what it reads as a failure, an edit and a verification on the commands a
  long, productive turn runs (upstream #128), how a turn item becomes a call, which
  thresholds a person may pin, and the judge's two calls. The plugin process and the MC
  are covered by `features/plugins/token-economizer-loop-guard.feature`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.TokenEconomizer
  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, Judge, Rules, ShellEdits, State, Turn}
  alias HalC2Plugins.TokenEconomizer.MicroSkills.{Distiller, EnvFacts}

  # Printed by Playwright on Windows as it exits, after a passing run as after a failing one.
  @libuv ~S"Assertion failed: !(handle->flags & UV_HANDLE_CLOSING), file src\win\async.c, line 76"

  test "the package reads, and its own defaults are settings it accepts" do
    dir = Path.expand("../../../../plugins/token-economizer", __DIR__)
    assert {:ok, manifest, sources, _hash} = HalC2.Plugins.Package.read(dir)
    assert manifest.id == "token-economizer"
    assert "token_economizer.ex" in Enum.map(sources, &Path.basename/1)

    defaults = Map.new(manifest.settings, &{&1.key, &1.default})
    assert :ok = TokenEconomizer.validate_settings(defaults)
    # The micro-skills are opt-in.
    assert defaults["microSkills"] == "off"
  end

  describe "an exit status covers a command unless its work could fail unseen" do
    for {cmd, covers} <- [
          {"npx playwright test spec.ts", true},
          {"cd apps/web && npx vitest run a.test.ts", true},
          {"cd apps/web; npx vitest run a.test.ts", true},
          {"cat apps/web/booking.ts", true},
          {"grep -rn BookingRequestError apps | head -20", true},
          {"git show HEAD:apps/web/booking.ts | sed -n '1,80p'", true},
          {"set -o pipefail; python repro.py | tail -5", true},
          {"set -euo pipefail\npython repro.py | tail -5", true},
          {"set +o pipefail; python repro.py | tail -5", false},
          {"set -o pipefail; set +o pipefail; python repro.py | tail -5", false},
          {"python repro.py | tail -5; set -o pipefail", false},
          {"echo 'set -o pipefail'; python repro.py | tail -5", false},
          {"python repro.py 2>&1 | tail -20", false},
          {"npm test; echo \"exit=$?\"", false},
          {"sed -i 's/a/b/' x.ts; npm test", false},
          {"make || true", false},
          {"SP=/tmp/x; cd $SP && python3 - <<'EOF'\nimport json\nprint('error outputs: 3')\nEOF",
           true},
          {"python3 - <<'EOF'\nprint(1)\nEOF\npython -m pytest -q | tail -3", false},
          {"", false}
        ] do
      test inspect(cmd) do
        assert Turn.exit_status_covers(unquote(cmd)) == unquote(covers)
      end
    end
  end

  defp command(cmd, output, status \\ "completed", extra \\ %{}) do
    Map.merge(
      %{
        "itemType" => "command_execution",
        "status" => status,
        "input" => cmd,
        "output" => output
      },
      extra
    )
  end

  test "a successful shell call exited zero where that status covers it" do
    assert {"bash", %{"command" => _}, _, 0} =
             TokenEconomizer.call_of(command("npx playwright test spec.ts", @libuv))

    assert {_, _, _, nil} =
             TokenEconomizer.call_of(command("python repro.py 2>&1 | tail", "Traceback"))

    # A zero is the last command's, which says nothing of a crash piped into it.
    crash =
      command("python -c 'raise RuntimeError(1)' 2>&1 | tail -n 4", "Traceback", "completed")

    assert {_, _, "Traceback", nil} =
             TokenEconomizer.call_of(Map.put(crash, "exitCode", 0))

    assert {_, _, _, 0} =
             TokenEconomizer.call_of(command("npm test", "", "completed", %{"exitCode" => 0}))

    # Never ran (an edit or a command the person declined): not a call.
    assert TokenEconomizer.call_of(command("npm test", "", "cancelled")) == nil

    assert TokenEconomizer.call_of(%{
             "itemType" => "file_change",
             "status" => "cancelled",
             "path" => "/r/a.py"
           }) == nil

    # A failure's own code wins.
    assert {_, _, _, 2} =
             TokenEconomizer.call_of(command("npm test", "", "failed", %{"exitCode" => 2}))

    assert {_, _, _, 1} = TokenEconomizer.call_of(command("npm test", "", "failed"))

    read = %{
      "itemType" => "dynamic_tool",
      "status" => "completed",
      "tool" => "Read",
      "input" => ~s({"file_path": "/r/a.ts"}),
      "output" => "x"
    }

    assert {"Read", %{"file_path" => "/r/a.ts"}, "x", nil} = TokenEconomizer.call_of(read)

    # A shell run as a dynamic tool is read like a command — 0 only when its
    # exit status covers the work, never for a status a pipe hid.
    for {command, code} <- [{"pytest -q", 0}, {"pytest -q 2>&1 | head -n 0", nil}] do
      shell = %{
        "itemType" => "dynamic_tool",
        "status" => "completed",
        "tool" => "Bash",
        "input" => JSON.encode!(%{"command" => command}),
        "output" => "4 passed"
      }

      assert {"Bash", %{"command" => ^command}, "4 passed", ^code} =
               TokenEconomizer.call_of(shell)
    end

    assert TokenEconomizer.call_of(%{"itemType" => "assistant_message", "status" => "completed"}) ==
             nil

    assert TokenEconomizer.call_of(%{"itemType" => "subagent", "status" => "completed"}) == nil
  end

  defp fold(g, name, args, result, code \\ nil) do
    {g, nil, nil} = Turn.fold(g, name, args, result, code)
    g
  end

  test "green Playwright runs are not failures, whatever libuv prints" do
    g =
      Enum.reduce([7, 5], Turn.new(), fn n, g ->
        out = "#{@libuv}\n  #{n} passed (23.6s)"

        g
        |> fold("Edit", %{"file_path" => "/r/apps/web/a.ts"}, "ok")
        |> fold("Bash", %{"command" => "npx playwright test spec.ts"}, out, 0)
        # Piped, the exit status is `tail`'s, and Playwright's own summary decides.
        |> fold("Bash", %{"command" => "npx playwright test spec.ts 2>&1 | tail -5"}, out, nil)
      end)

    assert g.whole.error_outputs == 0 and g.whole.repeated_fail_sigs == 0
    assert Turn.resolved_proxy(g) and g.whole.test_runs == 4

    assert Turn.runner_verdict("  1 failed\n    [chromium] a.spec.ts:3:1\n  6 passed (20.1s)") ==
             true
  end

  test "source read through the shell is not an error output, and a piped crash still is" do
    src =
      ~s|      if (!service) throw new BookingRequestError("unavailable", "Service not found");|

    g =
      Enum.reduce(
        [
          "cat apps/web/booking.ts",
          "sed -n '1,80p' apps/web/booking.ts",
          "grep -rn BookingRequestError apps | head -20"
        ],
        Turn.new(),
        fn cmd, g ->
          {name, args, out, code} = TokenEconomizer.call_of(command(cmd, src))
          fold(g, name, args, out, code)
        end
      )

    assert g.whole.error_outputs == 0

    {name, args, out, code} =
      TokenEconomizer.call_of(
        command(
          "python repro.py 2>&1 | tail -3",
          "Traceback (most recent call last):\nValueError: x"
        )
      )

    assert fold(g, name, args, out, code).whole.error_outputs == 1
  end

  test "putting back a file the turn never edited is not an edit" do
    revert = "git checkout -q -- apps/web/AGENTS.md"
    assert ShellEdits.targets(revert) == ["AGENTS.md"]
    assert ShellEdits.revert_targets(revert) == ["AGENTS.md"]

    # `next dev` keeps rewriting it; the agent puts it back.
    g =
      Enum.reduce(1..4, Turn.new(), fn _, g -> fold(g, "Bash", %{"command" => revert}, "", 0) end)

    assert State.edit_churn(g.whole) == 0 and g.edits == 0

    g =
      g
      |> fold("Edit", %{"file_path" => "/r/apps/web/page.tsx"}, "ok")
      |> fold("Bash", %{"command" => "git restore apps/web/page.tsx"}, "", 0)

    assert g.whole.edit_counts["page.tsx"] == 2 and g.edits == 2
  end

  test "a shell's script is read as the command only when nothing runs around it" do
    assert Turn.status_of_tests("bash -lc 'pytest -q'") == "own"
    assert Turn.status_of_tests("bash -lc 'true' && pytest -q") == "own"
    assert Turn.status_of_tests("bash -lc 'true'; pytest -q | tail -3") == "hidden"
    assert ShellEdits.targets("bash -lc 'true' && echo x > a.py") == ["a.py"]
    assert ShellEdits.targets("bash -lc 'sed -i s/a/b/ a.py' && pytest -q") == ["a.py"]

    # An edit, then a failing check after a nested shell: the check is the turn's last.
    g =
      Turn.new()
      |> fold("Edit", %{"path" => "a.py"}, "ok")
      |> fold("Bash", %{"command" => "bash -lc 'true' && pytest -q"}, "1 failed", 1)

    assert g.whole.test_runs == 1 and g.whole.error_outputs == 1
  end

  test "a vitest run behind dotenv is a verification and a test run" do
    cmd = "dotenv -e .env.local -- npx vitest run a.test.ts"
    assert Turn.status_of_tests(cmd) == "own"

    g =
      Turn.new()
      |> fold("Bash", %{"command" => cmd}, " Tests  3 passed (3)", 0)
      |> fold("Bash", %{"command" => "npx vitest run b.test.ts"}, " Tests  2 passed (2)", 0)

    assert g.verifications == 2 and g.st.test_runs == 2
  end

  test "successful edits of files containing assert or failed are not errors" do
    edit = %{
      "itemType" => "file_change",
      "status" => "completed",
      "path" => "/r/README.md",
      "output" => "the failed case asserts the value"
    }

    write = %{
      "itemType" => "file_change",
      "status" => "completed",
      "path" => "/r/test_a.py",
      "output" => "def test_x():\n    assert False, 'failed'\n"
    }

    g =
      Enum.reduce([edit, write, edit], Turn.new(), fn item, g ->
        {name, args, text, code} = TokenEconomizer.call_of(item)
        assert text == ""
        fold(g, name, args, text, code)
      end)

    assert g.whole.error_outputs == 0 and g.whole.repeated_fail_sigs == 0

    failure = %{
      edit
      | "status" => "failed",
        "output" => "Error: String to replace not found in file."
    }

    {name, args, text, code} = TokenEconomizer.call_of(failure)
    assert fold(g, name, args, text, code).whole.error_outputs == 1
  end

  describe "pinned thresholds" do
    test "a fractional count is refused, a whole one in any form is taken" do
      for name <-
            ~w(min_turns edit_churn distinct_edit_files error_outputs envelope_min_samples gate_min_turns gate_error_outputs) do
        assert :ok = TokenEconomizer.validate_settings(%{"loopGuardThresholds" => %{name => 8}})

        assert {:error, message} =
                 TokenEconomizer.validate_settings(%{"loopGuardThresholds" => %{name => 12.5}})

        assert message =~ "#{name} takes a whole number"
      end

      assert :ok =
               TokenEconomizer.validate_settings(%{
                 "loopGuardThresholds" => %{"min_turns" => 12.0, "stagnation" => 0.5}
               })
    end

    test "a share keeps to its range, and only thresholds are pinned" do
      assert {:error, "loopGuardThresholds: stagnation takes a number from 0.0 to 1.0."} =
               TokenEconomizer.validate_settings(%{
                 "loopGuardThresholds" => %{"stagnation" => 1.5}
               })

      assert {:error, "loopGuardThresholds: min_turns takes a whole number, 1 or more."} =
               TokenEconomizer.validate_settings(%{
                 "loopGuardThresholds" => %{"min_turns" => true}
               })

      assert {:error, "loopGuardThresholds: turns is not a threshold;" <> _} =
               TokenEconomizer.validate_settings(%{"loopGuardThresholds" => %{"turns" => 3}})

      assert {:error, _} = TokenEconomizer.validate_settings(%{"loopGuardNudges" => 1.5})
      assert {:error, _} = TokenEconomizer.validate_settings(%{"loopGuardNudges" => -1})
      assert :ok = TokenEconomizer.validate_settings(%{"loopGuardNudges" => 0})
    end
  end

  # A turn stuck by the strict rule: one file edited over and over, the same failing test.
  defp stuck_turn(g, calls, opts) do
    Enum.reduce(1..calls, {g, []}, fn i, {g, decisions} ->
      {g, decision, _job} =
        if rem(i, 2) == 0,
          do: Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, opts),
          else:
            Turn.fold(
              g,
              "Bash",
              %{"command" => "pytest -q"},
              "FAILED test_a.py::t - AssertionError: 1 != 2",
              1,
              opts
            )

      # As the plugin does: a redirect starts the agent's fresh segment.
      g =
        if match?({:nudge, _}, decision),
          do: g |> Turn.nudge_body() |> elem(1) |> Turn.after_nudge(),
          else: g

      {g, if(decision, do: decisions ++ [{i, decision}], else: decisions)}
    end)
  end

  # Folds a stuck turn's calls until the guard hands out a judge job.
  defp until_job(g, opts) do
    Enum.reduce_while(1..80, {g, nil}, fn i, {g, nil} ->
      {g, nil, job} =
        if rem(i, 2) == 0,
          do: edit(g, opts),
          else:
            Turn.fold(
              g,
              "Bash",
              %{"command" => "pytest -q"},
              "FAILED t - AssertionError",
              1,
              opts
            )

      if job, do: {:halt, {g, job}}, else: {:cont, {g, nil}}
    end)
  end

  defp edit(g, opts), do: Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, opts)

  describe "a stuck turn" do
    test "is not acted on before the project has an envelope" do
      {g, decisions} = stuck_turn(Turn.new("t"), 60, thr: Rules.defaults())
      assert decisions == []
      assert g.st.turns == 60
    end

    test "past the envelope is redirected once, then offered a stop once" do
      {_g, decisions} =
        stuck_turn(Turn.new("t"), 120, envelope: 10.0, thr: Rules.defaults(), nudge_budget: 1)

      assert [{_, {:nudge, _}}, {_, {:abort, _}}] = decisions
    end

    test "a turn whose checks pass after its last edit is not stopped at the backstop" do
      # Five learned four-call turns: an envelope of 5 calls, a backstop at 12.5.
      tracker = Envelope.new("default", %{}, %{"resolved_turns" => [4, 4, 4, 4, 4]})
      thr = Envelope.turn_thresholds(tracker)
      assert thr["backstop_turns"] == 12.5
      # As the plugin wires it: the judge is out on its job, its verdict still to come.
      thr = Map.merge(thr, %{"gate_over_envelope" => false, "gate_min_turns" => thr["min_turns"]})

      for budget <- [1, 0] do
        opts = [
          envelope: Envelope.envelope(tracker),
          thr: thr,
          judge: true,
          nudge_budget: budget,
          now: 0
        ]

        {g, []} = stuck_turn(Turn.new("t"), 12, opts)
        passing = %{"command" => "pytest -q"}
        assert {g, nil, nil} = Turn.fold(g, "Bash", passing, "3 passed in 0.10s", 0, opts)
        assert {_g, nil, nil} = Turn.fold(g, "Read", %{"file_path" => "/r/a.py"}, "", nil, opts)
        assert g.nudges_done == 0 and not g.aborted

        # An edit after it is unverified again, and the stuck turn is acted on.
        {_g, decision, _} = Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, opts)
        assert decision != nil
      end
    end

    test "a command that may hide a check after a passing one leaves the turn unverified" do
      tracker = Envelope.new("default", %{}, %{"resolved_turns" => [4, 4, 4, 4, 4]})
      thr = Envelope.turn_thresholds(tracker)
      thr = Map.merge(thr, %{"gate_over_envelope" => false, "gate_min_turns" => thr["min_turns"]})

      opts = [
        envelope: Envelope.envelope(tracker),
        thr: thr,
        judge: true,
        nudge_budget: 1,
        now: 0
      ]

      {g, []} = stuck_turn(Turn.new("t"), 12, opts)
      passing = %{"command" => "pytest -q"}
      {g, nil, nil} = Turn.fold(g, "Bash", passing, "3 passed in 0.10s", 0, opts)

      # Heard only in part (the plugin blanks a capped command) or a nested shell: either
      # may have run the checks again and failed, so the pass no longer covers the turn.
      for cmd <- ["", "bash -c 'pytest -q'"] do
        failing = %{"command" => cmd}
        {_g, decision, _} = Turn.fold(g, "Bash", failing, "FAILED t - AssertionError", 1, opts)
        assert decision != nil, inspect(cmd)
      end
    end

    test "an edit tried after a passing check, or after it in the same command, is unchecked" do
      tracker = Envelope.new("default", %{}, %{"resolved_turns" => [4, 4, 4, 4, 4]})
      thr = Envelope.turn_thresholds(tracker)
      thr = Map.merge(thr, %{"gate_over_envelope" => false, "gate_min_turns" => thr["min_turns"]})

      opts = [
        envelope: Envelope.envelope(tracker),
        thr: thr,
        judge: true,
        nudge_budget: 1,
        now: 0
      ]

      {g, []} = stuck_turn(Turn.new("t"), 12, opts)
      passing = "3 passed in 0.10s"

      # Checked, then an edit that failed to apply: what follows is no longer checked, as
      # upstream counts every edit it is told of.
      {g, nil, nil} = Turn.fold(g, "Bash", %{"command" => "pytest -q"}, passing, 0, opts)
      failed_edit = Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "not found", 1, opts)
      assert elem(failed_edit, 1) != nil

      # The run checked the code before the edit after it, not the edit, whatever joins
      # them; the edit before the run is what it checked.
      for {run_first, edit_first} <- [
            {"pytest -q && sed -i 's/a/b/' a.py", "sed -i 's/a/b/' a.py && pytest -q"},
            {"pytest -q; sed -i 's/a/b/' a.py", "sed -i 's/a/b/' a.py; pytest -q"},
            {"pytest -q || sed -i 's/a/b/' a.py", "sed -i 's/a/b/' a.py || pytest -q"},
            {"pytest -q | tee log && sed -i 's/a/b/' a.py",
             "sed -i 's/a/b/' a.py && pytest -q | tee log"},
            {"pytest -q\nsed -i 's/a/b/' a.py", "sed -i 's/a/b/' a.py\npytest -q"}
          ] do
        unchecked = Turn.fold(g, "Bash", %{"command" => run_first}, passing, 0, opts)
        assert elem(unchecked, 1) != nil, run_first
        checked = Turn.fold(g, "Bash", %{"command" => edit_first}, passing, 0, opts)
        assert {_, nil, nil} = checked, edit_first
      end
    end

    test "after a redirect the agent refused is offered a stop, whatever redirects are left" do
      opts = [envelope: 10.0, thr: Rules.defaults(), nudge_budget: 2]

      {g, decisions} =
        Enum.reduce(1..120, {Turn.new("t"), []}, fn i, {g, decisions} ->
          {g, decision, _job} =
            if rem(i, 2) == 0,
              do: edit(g, opts),
              else: Turn.fold(g, "Bash", %{"command" => "pytest -q"}, "FAILED t", 1, opts)

          # The provider could not take the redirect while it worked.
          g =
            if match?({:nudge, _}, decision),
              do: g |> Turn.redirect() |> Turn.redirected(false),
              else: g

          {g, if(decision, do: decisions ++ [decision], else: decisions)}
        end)

      assert [{:nudge, _}, {:abort, _}] = decisions
      assert g.nudges_done == 1

      # Nor is the judge asked to write one.
      judged = [envelope: 30.0, thr: Map.put(Rules.defaults(), "gate_over_envelope", false)]
      judged = judged ++ [judge: true, nudge_budget: 2, now: 0]
      refused = Turn.new("t") |> Turn.redirect() |> Turn.redirected(false)
      assert {_, %{"redirect" => false}} = until_job(refused, judged)
    end

    test "with no redirects left is offered a stop straight away" do
      {_g, decisions} =
        stuck_turn(Turn.new("t"), 120, envelope: 10.0, thr: Rules.defaults(), nudge_budget: 0)

      assert [{_, {:abort, _}}] = decisions
    end

    test "asks the background judge and acts only on its verdict" do
      opts = [
        envelope: 30.0,
        thr: Map.put(Rules.defaults(), "gate_over_envelope", false),
        judge: true,
        nudge_budget: 1,
        now: 0
      ]

      # Up to the gate, no job; then one job, and nothing decided while it is out.
      {g, job} =
        Enum.reduce_while(1..40, {Turn.new("t"), nil}, fn i, {g, nil} ->
          {g, nil, job} =
            if rem(i, 2) == 0,
              do: Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, opts),
              else:
                Turn.fold(
                  g,
                  "Bash",
                  %{"command" => "pytest -q"},
                  "FAILED t - AssertionError",
                  1,
                  opts
                )

          if job, do: {:halt, {g, job}}, else: {:cont, {g, nil}}
        end)

      assert job["id"] == "t:0:1"
      assert job["digest"] =~ "The last verification run failed."
      assert job["redirect"]

      # With no redirect left, a stuck verdict is offered as a stop: none is to be written.
      assert {_, %{"redirect" => false}} =
               until_job(Turn.new("t"), Keyword.put(opts, :nudge_budget, 0))

      assert {_, nil, nil} =
               Turn.fold(
                 g,
                 "Bash",
                 %{"command" => "pytest -q"},
                 "FAILED t - AssertionError",
                 1,
                 opts
               )

      # A verdict for another job is not this one's.
      assert Turn.verdict(g, "t:0:9", %{"stuck" => true, "confidence" => 0.9}).judge_arrived ==
               nil

      verdict = %{
        "stuck" => true,
        "confidence" => 0.9,
        "reason" => "loop",
        "_nudge" => "Try the other file.",
        "_tokens" => 40
      }

      g = Turn.verdict(g, job["id"], verdict)
      assert g.judge_tokens == 40

      {g, {:nudge, "judge-stuck@0.90:loop"}, nil} =
        Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, opts)

      assert {"Try the other file.", g} = Turn.nudge_body(g)
      g = Turn.after_nudge(g)
      assert g.segment == 1 and g.st.turns == 0 and g.judge_pending == nil
    end

    test "a judge that could not answer is no judge, so the aggressive level does not redirect on it" do
      opts = [
        envelope: 200.0,
        thr: Map.put(Rules.scaled_thresholds("aggressive"), "gate_over_envelope", false),
        judge: true,
        nudge_budget: 1,
        now: 0
      ]

      {g, job} = until_job(Turn.new("t"), opts)
      failed = Judge.stuck_judge(job["digest"], fn _, _ -> {:error, "no textGeneration"} end)
      unsure = %{"stuck" => nil, "confidence" => 0.4, "reason" => "unsure", "_tokens" => 0}

      # Within the envelope the rule without a judge spares the turn; an answer that is
      # really unsure still redirects it on this level.
      assert {_, nil, nil} = edit(Turn.verdict(g, job["id"], failed), opts)

      assert {_, {:nudge, "ambiguous-past-envelope"}, nil} =
               edit(Turn.verdict(g, job["id"], unsure), opts)
    end

    test "a judge job that never answers stops blocking the next one" do
      opts = [envelope: 30.0, thr: Rules.defaults(), judge: true, now: 0]
      {g, _} = stuck_turn(Turn.new("t"), 30, opts)
      assert %{"since" => 0} = g.judge_pending
      later = Keyword.put(opts, :now, Turn.judge_stale_s() + 1)
      {g, _} = stuck_turn(g, 12, later)
      assert g.judge_calls >= 2
    end

    test "decides nothing while its redirect is on its way, and starts afresh only once it lands" do
      opts = [envelope: 10.0, thr: Rules.defaults(), nudge_budget: 1]

      {g, [{_, {:nudge, _}}]} =
        Enum.reduce_while(1..120, {Turn.new("t"), []}, fn i, {g, _} ->
          {g, decision, _} =
            if rem(i, 2) == 0,
              do: edit(g, opts),
              else: Turn.fold(g, "Bash", %{"command" => "pytest -q"}, "FAILED t", 1, opts)

          if decision, do: {:halt, {Turn.redirect(g), [{i, decision}]}}, else: {:cont, {g, []}}
        end)

      # The calls the agent made before it took the redirect: still stuck, nothing decided.
      {g, decisions} = stuck_turn(g, 40, opts)
      assert decisions == [] and g.redirecting and g.segment == 0

      # Refused: the segment goes on, and its next stuck call is offered a stop.
      refused = Turn.redirected(g, false)
      assert refused.segment == 0 and refused.redirects == 0
      assert {_, [{1, {:abort, _}}]} = stuck_turn(refused, 2, opts)

      landed = Turn.redirected(g, true)
      assert landed.segment == 1 and landed.st.turns == 0 and landed.redirects == 1
    end

    test "a call heard after its redirect landed that started before it spends nothing" do
      # Thresholds pinned so low that one failing call is stuck, with a redirect left.
      thr =
        Map.merge(Rules.defaults(), %{
          "min_turns" => 1,
          "edit_churn" => 1,
          "error_outputs" => 1,
          "stagnation" => 0.0,
          "backstop_turns" => 1
        })

      opts = [envelope: 1.0, thr: thr, nudge_budget: 2]
      failing = &Turn.fold(&1, "Bash", %{"command" => "pytest -q"}, "FAILED t", 1, &2)

      g = Turn.new("t")
      {g, nil, _} = Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, started: 1)
      {g, {:nudge, _}, _} = failing.(g, opts ++ [started: 2])

      # The provider took the redirect when the thread's last place was 9.
      g = g |> Turn.redirect() |> Turn.redirected(true, 9)

      # The agent's edits and failing re-runs under way then, heard now: their places are
      # 9 or less, or not known. They count for the turn, not for the new segment.
      {g, decisions} =
        Enum.reduce([3, 9, nil, 5, 4, 8], {g, []}, fn started, {g, decisions} ->
          {g, decision, job} =
            if started in [3, nil, 4],
              do: Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, started: started),
              else: failing.(g, opts ++ [started: started])

          {g, decisions ++ [decision, job]}
        end)

      assert Enum.all?(decisions, &is_nil/1)
      assert g.nudges_done == 1 and not g.aborted and g.st.turns == 0
      assert g.cum_turns == 8 and g.whole.turns == 8

      # A call that started after it is the new segment's, and may decide.
      {g, nil, _} = Turn.fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", nil, started: 10)
      assert {_, {:nudge, _}, _} = failing.(g, opts ++ [started: 11])
    end

    test "a passing check after a script the turn wrote, in one && chain, says the turn is not stuck" do
      # Thresholds pinned so low that any call not verified is stuck.
      thr =
        Map.merge(Rules.defaults(), %{
          "min_turns" => 1,
          "edit_churn" => 1,
          "error_outputs" => 1,
          "stagnation" => 0.0,
          "backstop_turns" => 1
        })

      opts = [envelope: 1.0, thr: thr, nudge_budget: 2]

      # An edit and a failing run, heard before the project had an envelope.
      {edited, nil, nil} =
        Turn.new("t") |> Turn.fold("Edit", %{"file_path" => "/r/scripts/check.sh"}, "ok", nil)

      {edited, nil, nil} =
        Turn.fold(edited, "Bash", %{"command" => "pytest -q"}, "FAILED t\n1 failed", 1)

      run = &Turn.fold(edited, "Bash", %{"command" => &1}, "1 passed in 0.02s", 0, opts)

      assert {_, nil, nil} = run.("bash scripts/check.sh && pytest -q")
      # The script ran after the tests: it may have changed the tree, or run a check of its
      # own that failed unread. Not reading it costs a redirect here.
      assert {_, {:nudge, _}, _} = run.("pytest -q && bash scripts/check.sh")
    end
  end

  describe "the ended-green proxy" do
    test "a check run through mise exec is a verification, and its failure is not green" do
      assert Turn.status_of_tests("mise exec -- mix test test/a_test.exs") == "own"
      assert Turn.status_of_tests("mise x elixir@1.18 -- mix test") == "own"

      g =
        Turn.new()
        |> fold("Edit", %{"file_path" => "/r/a.ex"}, "ok")
        |> fold("Bash", %{"command" => "mise exec -- mix test"}, "1 test, 1 failure", 2)

      refute Turn.resolved_proxy(g)
    end

    test "a package manager's check filtered to a package is a verification" do
      for cmd <- [
            "pnpm --filter web test",
            "pnpm -F web run test",
            "pnpm --filter=web test",
            "pnpm -r test",
            "pnpm -C web test",
            "npm --prefix web test",
            "npm -w web run test",
            "npm --workspace=web test",
            "npm --workspaces --if-present test",
            "yarn workspace web test",
            "yarn --cwd web test",
            "bun --cwd web test",
            # Whether an option takes a value is the manager's: pnpm's `-w` is
            # `--workspace-root` and yarn's `-W` takes none, npm's `-w` names a workspace.
            "pnpm -w test",
            "pnpm -w run test",
            "yarn -W test",
            "npm -w web test"
          ] do
        assert Turn.status_of_tests(cmd) == "own", cmd

        failing =
          Turn.new()
          |> fold("Edit", %{"file_path" => "/r/a.ts"}, "ok")
          |> fold("Bash", %{"command" => cmd}, "Tests  1 failed (1)", 1)

        refute Turn.resolved_proxy(failing), cmd

        passing =
          Turn.new()
          |> fold("Edit", %{"file_path" => "/r/a.ts"}, "ok")
          |> fold("Bash", %{"command" => cmd}, "Tests  1 passed (1)", 0)

        assert Turn.resolved_proxy(passing), cmd
      end

      # An option this does not know may change what runs, or whether anything does: the
      # check is there, but not read.
      # An option another manager knows is one this manager does not: bun's `-r` preloads
      # a module, and `pnpm -w web` runs the root's `web` script.
      for cmd <- [
            "pnpm --frobnicate web test",
            "npm --dry-run test",
            "yarn -X run test",
            "pnpm -w web test",
            "npm -W test",
            "bun -r test",
            "yarn -r test"
          ] do
        assert Turn.status_of_tests(cmd) == "unknown", cmd

        passing =
          Turn.new()
          |> fold("Edit", %{"file_path" => "/r/a.ts"}, "ok")
          |> fold("Bash", %{"command" => cmd}, "Tests  1 passed (1)", 0)

        refute Turn.resolved_proxy(passing), cmd
      end

      assert Turn.status_of_tests("npm install test-utils") == nil
    end

    test "mix features, prop and proof are test runs, and a failing one is not green" do
      for task <- ~w(features prop proof),
          do: assert(Turn.status_of_tests("mise exec -- mix #{task} a.feature") == "own")

      g =
        Turn.new()
        |> fold("Edit", %{"file_path" => "/r/a.ex"}, "ok")
        |> fold(
          "Bash",
          %{"command" => "mise exec -- mix features plugins/token-economizer-loop-guard.feature"},
          "Result: 0/1 passed\nFailed: 1 test",
          2
        )

      refute Turn.resolved_proxy(g)
    end

    test "a pipe after pipefail is turned off hides the run's status, so its failing summary counts" do
      cmd = "set +o pipefail; pytest -q 2>&1 | tail -n 2"
      assert Turn.status_of_tests(cmd) == "hidden"
      assert Turn.status_of_tests("set -o pipefail; pytest -q 2>&1 | tail -n 2") == "own"

      g =
        Turn.new()
        |> fold("Edit", %{"file_path" => "/r/a.py"}, "ok")
        |> fold("Bash", %{"command" => cmd}, "==== 1 failed, 2 passed in 0.12s ====", 0)

      refute Turn.resolved_proxy(g)
    end

    test "a check negated, grouped, backgrounded or under a pipefail set elsewhere has no status" do
      for cmd <- [
            "! pytest -q",
            "(set -o pipefail); pytest -q 2>&1 | tail -n 2",
            "(pytest -q)",
            "cd x && (pytest -q)",
            "{ pytest -q; }",
            "if pytest -q; then echo ok; fi",
            "pytest -q &"
          ] do
        assert Turn.status_of_tests(cmd) == "unknown", cmd

        # Whatever the call reported, the run may have failed: it verifies nothing and
        # the turn is not learned.
        for {result, code} <- [{"1 failed in 0.02s", 0}, {"1 passed in 0.02s", 0}] do
          g =
            Turn.new()
            |> fold("Edit", %{"file_path" => "/r/a.py"}, "ok")
            |> fold("Bash", %{"command" => cmd}, result, code)

          assert g.verifications == 0, cmd
          refute Turn.resolved_proxy(g), cmd
        end
      end

      # A runner alone, or last in a pipe under a pipefail set at the top: its own.
      for cmd <- [
            "pytest -q",
            "set -o pipefail; pytest -q 2>&1 | tail -n 2",
            "cd x && pytest -q $(git ls-files 'test_*.py') ${ARGS:-}",
            "pytest -q 2>&1"
          ],
          do: assert(Turn.status_of_tests(cmd) == "own", cmd)
    end

    test "a test runner named in a heredoc's text is not a test run" do
      printed = "cat <<'EOF'\npytest -q\nEOF"
      assert Turn.status_of_tests(printed) == nil
      assert Turn.status_of_tests("bash -lc \"" <> printed <> "\"") == nil
      assert Turn.status_of_tests("python3 - <<EOF\nprint(1)\nEOF\npytest -q") == "own"

      g =
        Turn.new()
        |> fold("Edit", %{"file_path" => "/r/a.py"}, "ok")
        |> fold("Bash", %{"command" => "pytest -q"}, "FAILED t - AssertionError", 1)
        |> fold("Bash", %{"command" => printed}, "pytest -q", 0)

      refute Turn.resolved_proxy(g)
    end

    test "a shell edit that failed changed nothing, unless a test run after it is what failed" do
      g =
        Turn.new()
        |> fold("Bash", %{"command" => "pytest -q"}, "FAILED t - AssertionError", 1)

      failed = fold(g, "Bash", %{"command" => "sed -i 's/x/y/' missing.py"}, "No such file", 2)
      refute Turn.resolved_proxy(failed)
      assert failed.edits == 0

      assert Turn.resolved_proxy(fold(g, "Bash", %{"command" => "sed -i 's/x/y/' a.py"}, "", 0))

      checked =
        fold(g, "Bash", %{"command" => "sed -i 's/x/y/' a.py && pytest -q"}, "FAILED t", 1)

      assert checked.edits == 1
      refute Turn.resolved_proxy(checked)
    end

    test "an edit that failed changed nothing, so the failing check before it still counts" do
      g =
        Turn.new()
        |> fold("Bash", %{"command" => "pytest -q"}, "FAILED t - AssertionError", 1)
        |> fold("Edit", %{"file_path" => "/r/a.py"}, "String to replace not found in file.", 1)

      refute Turn.resolved_proxy(g)
      assert g.edits == 0

      assert Turn.resolved_proxy(fold(g, "Edit", %{"file_path" => "/r/a.py"}, "ok", 0))
    end
  end

  describe "the judge's digest" do
    defp digest(cmd),
      do: State.new() |> State.update("Bash", %{"command" => cmd}, "") |> State.recent_digest()

    defp shell_edit(cmd) do
      g = Turn.new()
      {g, nil, nil} = Turn.fold(g, "Bash", %{"command" => cmd}, "", 0)
      State.recent_digest(g.st)
    end

    test "names a command that writes files and their names, never what it writes" do
      patch =
        "apply_patch <<'PATCH'\n*** Begin Patch\n*** Update File: src/a.py\n" <>
          "+SECRET = 1\n*** End Patch\nPATCH"

      for cmd <- [
            patch,
            "bash -lc \"" <> patch <> "\"",
            "printf 'SECRET = 1\\n' > src/a.py",
            "sed -i 's/x = 0/SECRET = 1/' src/a.py",
            "cat > src/a.py <<EOF\nSECRET = 1\nEOF",
            "echo SECRET=1 > src/a.py",
            "cat > src/a.py <<'EOF-CODE'\nSECRET = 1\nEOF-CODE",
            "bash -lc 'echo SECRET=1 >> src/a.py && pytest -q'"
          ] do
        text = shell_edit(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
        assert text =~ "a.py", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # A plugin hears a command's last 4,000 characters: a long one may have lost its
      # heredoc's opening line, and what is left is the file it writes.
      long =
        HalC2.Orchestration.TurnWriter.observed_item(%{
          "id" => "i",
          "type" => "command_execution",
          "status" => "completed",
          "input" =>
            "cat > src/a.py <<'EOF'\n" <>
              String.duplicate("SECRET = 1\n", 500) <> "EOF\npytest -q",
          "output" => ""
        })

      {name, args, out, code} = TokenEconomizer.call_of(long)
      {g, nil, nil} = Turn.fold(Turn.new(), name, args, out, code)
      refute State.recent_digest(g.st) =~ "SECRET"

      assert shell_edit("echo SECRET=1 > src/a.py && pytest -q") =~ "echo; pytest …"

      assert ShellEdits.split_heredocs("cat <<'EOF-CODE'\nx\nEOF-CODE\nls") ==
               {"cat <<'EOF-CODE'\nls", ["x"]}

      assert ShellEdits.split_heredocs("grep x <<< \"$v\"\nls") == {"grep x <<< \"$v\"\nls", []}

      # Every heredoc a line opens is read, in order, whatever its form.
      assert ShellEdits.split_heredocs("cat <<'FIRST' <<'SECOND'\nx\nFIRST\ny\nSECOND\nls") ==
               {"cat <<'FIRST' <<'SECOND'\nls", ["x", "y"]}

      for cmd <- [
            "cat <<'FIRST' <<'SECOND'\nignored\nFIRST\nSECRET = 1\nSECOND",
            "cat <<A <<-B\nignored\nA\n\tSECRET = 1\n\tB\nls",
            "diff - /dev/fd/3 <<A 3<<\"B\"\nignored\nA\nSECRET = 1\nB",
            "grep x <<< y <<EOF\nSECRET = 1\nEOF"
          ] do
        text = digest(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # What only runs or searches keeps its words.
      assert digest(~s(grep -rn "def handle" src)) =~ ~s(grep -rn "def handle" src)
    end

    test "ends a heredoc where the shell does, and hides the rest when nothing ends it" do
      for cmd <- [
            # Any word is a delimiter.
            "python3 <<123\nSECRET = 1\n123",
            "cat <<@@ > notes.txt\nSECRET line\n@@",
            # Only the delimiter alone on its line ends the body: not indented without
            # `<<-`, nor with a space after it.
            "cat <<EOF\n  EOF\nSECRET words\nEOF",
            "cat <<EOF\nEOF \nSECRET words\nEOF",
            "cat <<\"E\"OF\nSECRET\nEOF\nls",
            "cat <<EOF\nSECRET"
          ] do
        text = digest(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # The delimiter is the word without its quotes, and `<<-` drops only leading tabs.
      assert ShellEdits.split_heredocs("cat <<\"E\"OF\nx\nEOF\nls") ==
               {"cat <<\"E\"OF\nls", ["x"]}

      assert ShellEdits.split_heredocs("cat <<E\\OF\nx\nEOF\nls") == {"cat <<E\\OF\nls", ["x"]}

      assert ShellEdits.split_heredocs("cat <<-EOF\n\tx\n\tEOF\nls") ==
               {"cat <<-EOF\nls", ["\tx"]}

      # A line continued with a backslash is one line, and its heredoc starts after it.
      assert ShellEdits.targets("sed -i \\\n  's/a/b/' a.py") == ["a.py"]
      assert ShellEdits.targets("cat <<EOF \\\n  > a.py\nSECRET = 1\nEOF\nls") == ["a.py"]
      refute digest("cat <<EOF \\\n  > a.py\nSECRET = 1\nEOF") =~ "SECRET"
    end

    test "reads a redirect run together with the operator before it" do
      for cmd <- [
            "(echo SECRET)>a.py",
            "true;>a.py echo SECRET",
            "true&&>a.py echo SECRET",
            "echo SECRET >& a.py"
          ] do
        assert ShellEdits.targets(cmd) == ["a.py"], cmd
        text = digest(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # Duplicating a descriptor writes no file.
      assert ShellEdits.targets("pytest 2>&1 | tee log") == []
      assert digest("pytest -q tests >&2") =~ "pytest -q tests >&2"
    end

    test "counts a source file a copy, move, dd, sponge or truncate writes" do
      for {cmd, files} <- [
            {"echo SECRET | dd of=src/a.py", ["a.py"]},
            {"printf SECRET | dd of=a.py status=none", ["a.py"]},
            {"echo SECRET | sponge a.py", ["a.py"]},
            {"cp /tmp/new.py src/a.py", ["a.py"]},
            {"mv -f a.py.new a.py", ["a.py"]},
            {"install -m 644 new.py a.py", ["a.py"]},
            {"cp new.py other.py src/", ["new.py", "other.py"]},
            {"mv -t src new.py", ["new.py"]},
            {"truncate -s 0 a.py", ["a.py"]}
          ] do
        assert ShellEdits.targets(cmd) == files, cmd
        text = digest(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # A copy kept aside, or one into scratch, is not an edit.
      assert ShellEdits.targets("cp a.py a.py.bak") == []
      assert ShellEdits.targets("cp -r src backup") == []
      assert ShellEdits.targets("dd if=/dev/zero of=/tmp/x.py count=1") == []
    end

    test "counts an edit behind a wrapper, in a nested shell, or with its script attached" do
      for {cmd, files} <- [
            {"sed -i -e's/a/b/' a.py", ["a.py"]},
            {"sed --expression=s/a/b/ -i a.py", ["a.py"]},
            {"perl -pi -e's/a/b/' a.py", ["a.py"]},
            {"sudo -u me sed -i 's/a/b/' a.py", ["a.py"]},
            {"timeout 10 sed -i 's/a/b/' a.py", ["a.py"]},
            {"nice -n 5 perl -pi -e 's/a/b/' a.py", ["a.py"]},
            # Files fed in on stdin, or found, are edited too, whatever their names.
            {"grep -rl foo . | xargs sed -i 's/foo/bar/'", ["(sed)"]},
            {"find . -name '*.py' -exec sed -i 's/a/b/' {} +", ["(sed)"]},
            {"git -C repo apply x.diff", ["(patch)"]},
            {"cd x && bash -c 'echo SECRET > a.py'", ["a.py"]},
            {"cd x && sh -ec \"sed -i 's/a/SECRET/' a.py\"", ["a.py"]},
            {"eval \"echo SECRET > a.py\"", ["a.py"]},
            {"echo SECRET > ./src/a'.py'", ["a.py"]}
          ] do
        assert ShellEdits.targets(cmd) == files, cmd
        text = shell_edit(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      assert ShellEdits.revert_targets("git -C repo checkout -- a.py") == ["a.py"]
      # A wrapper that runs no editor edits nothing.
      assert ShellEdits.targets("timeout 60 pytest -q") == []
    end

    test "keeps an operator quoted inside a word in the word" do
      for cmd <- [
            "sed -i -e'1iPRIVATE_SOURCE;PRIVATE_TOKEN' a.py",
            "sed -i -e\"1iPRIVATE_SOURCE|PRIVATE_TOKEN\" a.py",
            "printf x';'PRIVATE_TOKEN'&&'PRIVATE_SOURCE > a.py"
          ] do
        assert ShellEdits.targets(cmd) == ["a.py"], cmd
        assert ShellEdits.programs(cmd) in [["sed"], ["printf"]], cmd
        refute shell_edit(cmd) =~ "PRIVATE", cmd
      end

      # A word the shell joins from quoted and bare parts is one word.
      assert ShellEdits.tokens("echo 'a;b'c\"d|e\"f > x") ==
               {:ok, ["echo", "'a;b'c\"d|e\"f", ">", "x"]}
    end

    test "counts an edit inside a group, a branch or a loop" do
      for cmd <- [
            "{ tee a.py <<< SECRET; }",
            "{ sed -i 's/a/SECRET/' a.py; }",
            "if true; then sed -i 's/a/SECRET/' a.py; fi",
            "for f in x; do perl -pi -e 's/a/SECRET/' a.py; done",
            "while false; do :; done; ! sed -i s/a/SECRET/ a.py"
          ] do
        assert ShellEdits.targets(cmd) == ["a.py"], cmd
        refute shell_edit(cmd) =~ "SECRET", cmd
      end
    end

    test "counts a file gawk edits in place" do
      for {cmd, files} <- [
            {"awk -i inplace '{print \"SECRET\"}' a.py", ["a.py"]},
            {"gawk -i inplace -v x=1 -f fix.awk a.py b.py", ["a.py", "b.py"]},
            {"gawk --include=inplace '{print}' a.py", ["a.py"]}
          ] do
        assert ShellEdits.targets(cmd) == files, cmd
        refute shell_edit(cmd) =~ "SECRET", cmd
      end

      assert ShellEdits.targets("awk '{print}' a.py > /dev/null") == []
    end

    test "shows only the programs of a command whose words may be code it cannot read" do
      for cmd <- [
            "X=$'it\\'s SECRET' pytest",
            "git commit -m \"fix\nSECRET\"",
            "git commit -m 'fix\nSECRET'",
            "echo 'SECRET' | python3",
            "printf 'SECRET' | node -",
            "curl -s https://x | sh",
            "echo \"SECRET > a.py",
            "cd x && bash -c 'echo SECRET'",
            "eval \"echo SECRET\"",
            "ls | xargs -I{} sh -c 'echo SECRET {}'"
          ] do
        text = digest(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      assert digest("echo 'SECRET' | python3") =~ "$ echo; python3 …"

      for cmd <- ["pytest -q tests", "git commit -m \"fix it\"", "python3 -m pytest -q"] do
        assert digest(cmd) =~ "$ #{cmd}"
      end
    end

    test "reads a backslash and a word's # as the shell does" do
      # Escaped, an operator or a quote is part of the word; in double quotes, `\"` and
      # `\\` do not end it; `#` starts a comment only at a word's start.
      for cmd <- [
            ~S{printf %s prefix\;PRIVATE_SOURCE > a.py},
            ~S{sed -i -e"s/x/\";PRIVATE_SOURCE;\"/" a.py},
            ~S{echo it\'s\;PRIVATE_SOURCE > a.py},
            "printf %s x#;printf PRIVATE_SOURCE > a.py"
          ] do
        assert ShellEdits.targets(cmd) == ["a.py"], inspect(cmd)
        text = digest(cmd)
        refute text =~ "PRIVATE_SOURCE", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      assert ShellEdits.tokens(~S{a\;b "c\"d\\" e\ f x#y #z}) ==
               {:ok, [~S{a\;b}, ~S{"c\"d\\"}, ~S{e\ f}, "x#y"]}

      assert ShellEdits.tokens("a\\") == :error
      assert ShellEdits.targets(~S{sed -i 's/x/y/' a\ b.py}) == ["a b.py"]
      assert ShellEdits.targets(~S{echo x > "a\"b.py"}) == [~S{a"b.py}]
    end

    test "shows a command it cannot read every character of as a shell command, never its words" do
      for cmd <- [
            ~S|printf "$(echo "x;PRIVATE_SOURCE")" > a.py|,
            ~S|printf "${X:-"a;PRIVATE_SOURCE"}" > a.py|,
            ~S{printf "`echo "a;PRIVATE_SOURCE"`" > a.py},
            ~S{printf $'a\';PRIVATE_SOURCE' > a.py},
            ~S{printf $"a;PRIVATE_SOURCE" > a.py}
          ] do
        text = digest(cmd)
        refute text =~ "PRIVATE_SOURCE", "#{inspect(cmd)} showed #{inspect(text)}"
        assert text =~ "$ <shell command>", inspect(cmd)
      end

      # A comment is dropped, so the command's characters no longer add up to its words.
      assert digest("cat a.py # PRIVATE_SOURCE") =~ "$ <shell command>"
      assert digest(~S{rg -n "foo\(" src}) =~ ~S{$ rg -n "foo\(" src}
    end

    test "never shows what a command writes to a file it does not count as an edit" do
      for cmd <- [
            "echo SECRET=1 > Makefile",
            "echo SECRET=1 > /tmp/a.py",
            "printf 'SECRET=1' | tee out.log",
            "bash -lc 'echo SECRET=1 > .env'"
          ] do
        text = shell_edit(cmd)
        refute text =~ "SECRET", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # A QML file is source: written, it is an edit, and its words are not shown.
      assert ShellEdits.targets("echo SECRET=1 > src/Main.qml") == ["Main.qml"]
      refute shell_edit("echo SECRET=1 > src/Main.qml") =~ "SECRET"

      # Output thrown away writes nothing.
      assert shell_edit("pytest -q tests/test_a.py > /dev/null 2>&1") =~ "tests/test_a.py"
    end

    test "never shows a value a command sets, text it feeds in, or code it runs inline" do
      for cmd <- [
            "API_TOKEN=s3cr3t-xyz pytest -q",
            "export API_TOKEN=s3cr3t-xyz",
            "env API_TOKEN=s3cr3t-xyz npm test",
            "cd src && API_TOKEN='s3cr3t xyz' ./run.sh",
            ~s(API_TOKEN="s3cr3t \\"xyz\\"" ./run.sh),
            ~S(API_TOKEN=s3cr3t\ xyz pytest -q),
            "grep x <<< s3cr3t-xyz",
            ~s(grep x <<<"s3cr3t xyz"),
            ~s{python3 -c "print('s3cr3t-xyz')"},
            ~s{node -e "require('fs').writeFileSync('a', 's3cr3t-xyz')"},
            ~s{ruby -e 'File.write("a", "s3cr3t-xyz")'},
            "bash -lc 'export API_TOKEN=s3cr3t-xyz && pytest -q'"
          ] do
        text = digest(cmd)
        refute text =~ "s3cr3t", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # What the command is stays: the names it sets, and the programs it runs.
      assert digest("API_TOKEN=s3cr3t-xyz pytest -q") =~ "$ API_TOKEN=… pytest -q"
      assert digest(~s{node -e "require('fs')"}) =~ "$ node …"
      assert digest("pytest --maxfail=1 -k a=b") =~ "pytest --maxfail=1 -k a=…"
    end

    test "shows only the programs of a command with any redirect but a read or a duplication" do
      for cmd <- [
            "printf %s PRIVATE_SOURCE 1<>a.py",
            "printf PRIVATE_SOURCE <>notes.txt",
            "printf PRIVATE_SOURCE >&out.txt",
            "printf PRIVATE_SOURCE <&out.txt",
            "printf PRIVATE_SOURCE >&$fd",
            "printf PRIVATE_SOURCE > >(cat)"
          ] do
        text = digest(cmd)
        refute text =~ "PRIVATE_SOURCE", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # Reading a file, discarding output and duplicating a descriptor write nothing.
      for cmd <- [
            "pytest -q < args.txt",
            "pytest -q >/dev/null 2>&1",
            "pytest -q 2>&1",
            "pytest -q >&2",
            "pytest -q 0<&3"
          ] do
        assert digest(cmd) =~ "$ #{cmd}"
      end
    end

    test "shows only the programs of an interpreter handed code anywhere in its words" do
      for cmd <- [
            ~s{node --input-type commonjs -e "require('fs').writeFileSync('a','PRIVATE_SOURCE')"},
            "node --import=data:text/javascript,PRIVATE_SOURCE app.js",
            ~s{python3 -X dev -W error -c "open('a','w').write('PRIVATE_SOURCE')"},
            ~s{timeout 10 ruby -w -e 'File.write("a", "PRIVATE_SOURCE")'},
            "find . -name a -exec perl -0777 -pe 's/x/PRIVATE_SOURCE/' {} +",
            ~s{deno eval "Deno.writeTextFileSync('a', 'PRIVATE_SOURCE')"},
            ~s|awk 'BEGIN { print "PRIVATE_SOURCE" > "a.py" }'|,
            # Behind a launcher, or any program that runs another after its own words.
            ~s|mise exec -- node -e 'require("fs").writeFileSync("a.py","PRIVATE_SOURCE")'|,
            ~s|mise x node@20 -- node -e 'require("fs").writeFileSync("a","PRIVATE_SOURCE")'|,
            ~s|npx node -e 'require("fs").writeFileSync("a","PRIVATE_SOURCE")'|,
            ~s|uv run python -c "open('a','w').write('PRIVATE_SOURCE')"|,
            ~s|poetry run python3 -c "open('a','w').write('PRIVATE_SOURCE')"|,
            ~s|pnpm exec node --eval 'require("fs").writeFileSync("a","PRIVATE_SOURCE")'|,
            ~s|mise exec -- bash -c 'echo PRIVATE_SOURCE'|
          ] do
        text = digest(cmd)
        refute text =~ "PRIVATE_SOURCE", "#{inspect(cmd)} showed #{inspect(text)}"
      end

      # A module or a script run, and the words that are its own, are shown.
      for cmd <- [
            "python3 -m pytest -rA -p no:cacheprovider",
            "python -W error tests/runtests.py --verbose",
            "node --test",
            "ruby -Ilib test/a_test.rb",
            "awk -f count.awk a.txt",
            "uv run pytest -q",
            "mise exec -- npm test"
          ] do
        assert digest(cmd) =~ "$ #{cmd}"
      end
    end
  end

  describe "missed events" do
    defp observe(state, event) do
      {:reply, :ok, state} = TokenEconomizer.handle_call({:observe, event}, nil, state)
      state
    end

    defp started(thread, extra \\ %{}) do
      Map.merge(
        %{
          "type" => "turn.started",
          "threadId" => thread,
          "runId" => "run-" <> thread,
          "projectId" => "p",
          "provider" => "claudeAgent"
        },
        extra
      )
    end

    # Thread "a"'s turn, its items heard in order. Never closed: a closed turn that
    # learns writes its project's envelope to the plugin's data directory.
    defp heard_turn(items) do
      {:ok, state} = TokenEconomizer.init(%{})
      at = %{"type" => "turn.item", "threadId" => "a", "runId" => "run-a"}
      Enum.reduce(items, observe(state, started("a")), &observe(&2, Map.merge(at, &1)))
    end

    defp edited(path), do: %{"itemType" => "file_change", "status" => "completed", "path" => path}

    test "mark partial the turns under way and those heard before the feed's queue drains" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = observe(state, started("a"))
      # Reported on an event queued before the missed ones, with one more waiting: "b"
      # and "c" may have lost them.
      state =
        state
        |> observe(started("b", %{"dropped" => 3, "waiting" => 1}))
        |> observe(started("c"))

      assert state.turns["a"].partial and state.turns["b"].partial and state.turns["c"].partial

      state = observe(state, started("d"))
      refute state.turns["d"].partial
    end

    test "keep the window a report of missed events opens while off" do
      {:ok, state} = TokenEconomizer.init(%{"loopGuard" => "off"})
      # Turned off, the guard hears a report with a turn's start still waiting behind it.
      state = observe(state, %{"type" => "noop", "dropped" => 2, "waiting" => 1})
      {:reply, :ok, state} = TokenEconomizer.handle_call({:settings, %{}}, nil, state)
      state = observe(state, started("a"))
      assert state.turns["a"].partial

      state = observe(state, started("b"))
      refute state.turns["b"].partial
    end

    test "after a restart, take every event the feed still holds or is delivering as possibly before missed ones" do
      # This process stands in for the plugin's feed, still running, with three events
      # queued: the report of missed events went to the process that went down. No
      # synchronous test runs alongside this one, so the hooks' registry is this test's.
      start_supervised!({Registry, keys: :unique, name: HalC2.Plugins.Hooks})

      {:ok, _} =
        Registry.register(HalC2.Plugins.Hooks, {:observe, "token-economizer"}, %{
          id: "token-economizer",
          dropped: :counters.new(1, [])
        })

      for i <- 1..3, do: send(self(), {:queued, i})
      {:ok, state} = TokenEconomizer.init(%{})
      # The feed may be blocked delivering one more, sent to this process while it
      # started: that one is heard first, and the three queued after it.
      state = state |> observe(started("a")) |> observe(%{"type" => "noop"})
      state = state |> observe(%{"type" => "noop"}) |> observe(started("b"))
      assert state.turns["a"].partial and state.turns["b"].partial

      state = observe(state, started("c"))
      refute state.turns["c"].partial
    end

    test "drop a turn whose run ended unheard once two sweeps found it so, learning nothing from it" do
      {:ok, state} = TokenEconomizer.init(%{})
      # The MC says run-a ended: its `turn.finished` was lost, or is still on its way.
      state = %{state | active?: fn _thread, run -> run != "run-a" end}
      state = state |> observe(started("a")) |> observe(started("b"))

      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      assert Map.keys(state.turns) == ["a", "b"]

      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      assert Map.keys(state.turns) == ["b"]
      assert state.stats["turns"] == 1
      assert state.trackers == %{}

      # A turn that started on the thread since is the MC's to answer for afresh.
      state = observe(state, started("a", %{"runId" => "run-a2"}))
      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      assert Map.keys(state.turns) == ["a", "b"]
      Process.cancel_timer(state.sweep)
    end

    test "count a turn whose run the MC could not answer for as ended, so a failing MC keeps none for good" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = %{state | active?: fn _thread, _run -> raise "no stream" end}
      state = observe(state, started("a"))

      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      assert state.turns == %{}
      Process.cancel_timer(state.sweep)
    end

    test "count what was waiting, which a full queue does not bound" do
      {:ok, state} = TokenEconomizer.init(%{})
      # Senders that found room together put more than the limit in the queue.
      waiting = HalC2.Plugins.Feed.max_queue() + 5
      state = observe(state, %{"type" => "noop", "dropped" => 1, "waiting" => waiting})
      state = Enum.reduce(2..waiting, state, fn _, s -> observe(s, %{"type" => "noop"}) end)
      state = observe(state, started("last"))
      assert state.turns["last"].partial

      state = observe(state, started("after"))
      refute state.turns["after"].partial
    end
  end

  describe "the envelope" do
    test "learns only from turns that ended green, and only past enough of them" do
      tracker = Envelope.new()
      green = fold(Turn.new(), "Edit", %{"file_path" => "/r/a.py"}, "ok")

      tracker = Enum.reduce(1..4, tracker, fn _, t -> Envelope.record_turn(t, green, true) end)
      assert Envelope.envelope(tracker) == nil
      assert Envelope.record_turn(tracker, green, false) == tracker

      red = fold(green, "Bash", %{"command" => "pytest"}, "1 failed in 0.1s", 1)
      assert Envelope.record_turn(tracker, red, true) == tracker

      tracker = Envelope.record_turn(tracker, green, true)
      assert Envelope.envelope(tracker) == 1.25
    end

    test "never pins signal gates below the level, and a person's values win" do
      snaps =
        for _ <- 1..5,
            do: %{
              "edit_churn" => 1,
              "distinct_edit_files" => 1,
              "error_outputs" => 0,
              "stagnation" => 0.0
            }

      tracker =
        Envelope.new("default", %{}, %{
          "resolved_turns" => [40, 40, 40, 40, 40],
          "resolved_snaps" => snaps
        })

      thr = Envelope.turn_thresholds(tracker, %{"edit_churn" => 9})
      assert thr["edit_churn"] == 9
      assert thr["error_outputs"] == Rules.defaults()["error_outputs"]
      assert thr["min_turns"] == 20 and thr["gate_min_turns"] == 18
      assert thr["backstop_turns"] == 50.0 * 2.5

      saved = tracker |> Envelope.dump() |> JSON.encode!() |> JSON.decode!()
      assert Envelope.new("default", %{}, saved).resolved_turns == tracker.resolved_turns
    end

    test "rounds half to even, as Python does" do
      assert Enum.map([0.5, 1.5, 2.5, 2.4, 2.6], &Envelope.round_even/1) == [0, 2, 2, 2, 3]
    end
  end

  describe "the judge" do
    # What a call asked for: its prompt and the schema its reply is checked against.
    defp asked(call) do
      case_ = self()
      call.(fn prompt, schema -> send(case_, {:asked, prompt, schema}) && {:error, "none"} end)
      assert_received {:asked, prompt, schema}
      {prompt, schema}
    end

    # Pi and ACP agents are given the prompt alone, and their reply is checked against
    # the schema all the same: the prompt names the object and each key's type.
    defp asks_for_its_schema({prompt, schema}) do
      assert prompt =~ "JSON object"
      for {key, type} <- schema, do: assert(prompt =~ ~s("#{key}" (a #{type}), key)
    end

    test "asks for the verdict as the JSON object it is checked against" do
      asks_for_its_schema(asked(&Judge.stuck_judge("digest", &1)))
    end

    test "asks for the redirect as the JSON object it is checked against" do
      asks_for_its_schema(asked(&Judge.nudge_writer("digest", &1)))
    end

    test "writes the redirect only for a stuck verdict it is sure of" do
      sure = fn
        _prompt, %{"stuck" => _} ->
          {:ok, %{"stuck" => true, "confidence" => "0.9", "reason" => "same test"},
           %{"inputTokens" => 10, "outputTokens" => 2}}

        _prompt, %{"text" => _} ->
          {:ok, %{"text" => "  Read the failing test first.  "},
           %{"inputTokens" => 5, "outputTokens" => 3}}
      end

      assert %{
               "stuck" => true,
               "confidence" => 0.9,
               "_nudge" => "Read the failing test first.",
               "_tokens" => 20
             } =
               Judge.run("digest", 0.7, sure)

      unsure = fn _prompt, %{"stuck" => _} ->
        {:ok, %{"stuck" => true, "confidence" => "0.5", "reason" => "?"}, %{}}
      end

      refute Map.has_key?(Judge.run("digest", 0.7, unsure), "_nudge")

      # With no redirect left to send, a stuck verdict is offered as a stop: no writer.
      judge_only = fn _prompt, %{"stuck" => _} = schema -> sure.("", schema) end

      assert %{"stuck" => true, "_tokens" => 12} =
               run = Judge.run("digest", 0.7, judge_only, false)

      refute Map.has_key?(run, "_nudge")

      # A reply with no words is paid for all the same, and cached input is part of the
      # input, not more of it.
      blank = fn
        _prompt, %{"stuck" => _} ->
          {:ok, %{"stuck" => true, "confidence" => 0.9, "reason" => "same test"},
           %{"inputTokens" => 10, "cachedInputTokens" => 8, "outputTokens" => 2}}

        _prompt, %{"text" => _} ->
          {:ok, %{"text" => "  \n "}, %{"inputTokens" => 5, "outputTokens" => 3}}
      end

      blank_run = Judge.run("digest", 0.7, blank)
      assert blank_run["_tokens"] == 20
      refute Map.has_key?(blank_run, "_nudge")

      failing = fn _, _ -> {:error, "no model"} end
      assert %{"stuck" => nil} = Judge.run("digest", 0.7, failing)

      assert Rules.read_verdict(Judge.run("digest", 0.7, failing), Rules.defaults()) ==
               {false, "judge-ambiguous-spared"}
    end
  end

  describe "the plugin's redirects and judge jobs" do
    defp sleeper(state, thread, kind) do
      {:ok, pid} = Task.Supervisor.start_child(state.sup, fn -> Process.sleep(:infinity) end)
      Process.monitor(pid)
      {pid, put_in(state.tasks[pid], {thread, kind})}
    end

    defp redirecting(thread) do
      {:ok, state} = TokenEconomizer.init(%{})
      state = observe(state, started(thread))
      update_in(state.turns[thread].guard, &Turn.redirect/1)
    end

    defp delivered(state, thread, result) do
      entry = %{"threadId" => thread, "runId" => "run-" <> thread, "action" => "nudge"}

      {:noreply, state} =
        TokenEconomizer.handle_info({:delivered, thread, "run-" <> thread, entry, result}, state)

      state
    end

    test "a refused redirect is not reported as delivered and leaves the segment as it was" do
      state =
        delivered(redirecting("a"), "a", {:error, "Codex cannot take messages while it works."})

      guard = state.turns["a"].guard
      refute guard.redirecting
      assert guard.segment == 0 and guard.redirects == 0
      assert [%{"action" => "nudge", "delivered" => false}] = state.recent
    end

    # A steer its runtime still held when its budget ran out may reach the agent later, or
    # never: the agent is not known to have the redirect, so it starts no segment and
    # names no place, and the turn's judge job runs on.
    test "a redirect the MC sent but did not hear taken has not landed" do
      {judge, state} = sleeper(redirecting("a"), "a", :judge)
      state = delivered(state, "a", {:ok, %{"ordinal" => 7, "confirmed" => false}})

      guard = state.turns["a"].guard
      refute guard.redirecting
      assert guard.segment == 0 and guard.redirects == 0 and guard.since == nil
      assert Process.alive?(judge)
      assert [%{"action" => "nudge", "delivered" => false}] = state.recent
    end

    test "a redirect that landed starts the next segment and stops the old segment's judge job" do
      {judge, state} = sleeper(redirecting("a"), "a", :judge)
      {other, state} = sleeper(state, "b", :judge)
      state = delivered(state, "a", {:ok, %{}})

      assert_receive {:DOWN, _, :process, ^judge, _}
      assert Process.alive?(other)
      assert state.turns["a"].guard.segment == 1
      assert [%{"delivered" => true}] = state.recent
    end

    test "a judge job gone stale is stopped when a new one replaces it" do
      {:ok, state} = TokenEconomizer.init(%{})
      saved = %{"level" => "default", "resolved_turns" => List.duplicate(30, 5)}
      state = put_in(state.trackers[{"p", "claudeAgent"}], Envelope.new("default", %{}, saved))
      state = observe(state, started("a"))
      {old, state} = sleeper(state, "a", :judge)
      since = System.monotonic_time(:second) - Turn.judge_stale_s() - 1
      pending = %{"id" => "a:0:1", "since" => since, "segment" => 0}
      state = update_in(state.turns["a"].guard, &%{&1 | judge_pending: pending, judge_calls: 1})

      state = stuck_until(state, &(&1.stats["judgeCalls"] > 0))
      assert state.stats["judgeCalls"] == 1
      assert_receive {:DOWN, _, :process, ^old, _}
      assert [{_, {"a", :judge}}] = Map.to_list(state.tasks)
    end

    test "a stop offer stops the turn's judge job, whose verdict nothing would read" do
      {:ok, state} = TokenEconomizer.init(%{"loopGuard" => "watch", "loopGuardNudges" => 0})
      # Five learned four-call turns: the backstop at 12.5 calls.
      saved = %{"level" => "default", "resolved_turns" => [4, 4, 4, 4, 4]}
      state = put_in(state.trackers[{"p", "claudeAgent"}], Envelope.new("default", %{}, saved))
      state = observe(state, started("a"))
      {judge, state} = sleeper(state, "a", :judge)
      pending = %{"id" => "a:0:1", "since" => System.monotonic_time(:second), "segment" => 0}
      state = update_in(state.turns["a"].guard, &%{&1 | judge_pending: pending, judge_calls: 1})

      state = stuck_until(state, &(&1.stats["aborts"] > 0))
      assert state.stats["aborts"] == 1
      assert_receive {:DOWN, _, :process, ^judge, _}
      assert state.tasks == %{}
    end

    # Feeds thread `a` an edit and a failing check, in turn, until `done?` holds.
    defp stuck_until(state, done?) do
      Enum.reduce_while(1..60, state, fn i, state ->
        item =
          if rem(i, 2) == 0,
            do: %{"itemType" => "file_change", "status" => "completed", "path" => "/r/a.py"},
            else: command("pytest -q", "FAILED t - AssertionError", "failed", %{"exitCode" => 1})

        state =
          observe(
            state,
            Map.merge(item, %{"type" => "turn.item", "threadId" => "a", "runId" => "run-a"})
          )

        if done?.(state), do: {:halt, state}, else: {:cont, state}
      end)
    end

    test "a cancelled edit after a failing check changes nothing, so the turn does not end green" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = observe(state, started("a"))
      at = %{"type" => "turn.item", "threadId" => "a", "runId" => "run-a"}

      state =
        state
        |> observe(
          Map.merge(at, %{
            "itemType" => "file_change",
            "status" => "completed",
            "path" => "/r/a.py"
          })
        )
        |> observe(
          Map.merge(
            at,
            command("pytest -q", "FAILED t - AssertionError", "failed", %{"exitCode" => 1})
          )
        )
        |> observe(
          Map.merge(at, %{
            "itemType" => "file_change",
            "status" => "cancelled",
            "path" => "/r/a.py"
          })
        )

      guard = state.turns["a"].guard
      assert guard.edits == 1 and guard.cum_turns == 2
      refute Turn.resolved_proxy(guard)
    end

    test "a failing vp test run after an edit is a failed check, so the turn is not learned" do
      for cmd <- ["vp test run src/a.test.ts", "vp test", "vp run test"] do
        state =
          heard_turn([
            edited("/r/a.ts"),
            command(cmd, "FAIL src/a.test.ts", "failed", %{"exitCode" => 1})
          ])

        refute TokenEconomizer.learns?(state.turns["a"], true), cmd
        assert state.turns["a"].guard.last_verify_failed, cmd
      end
    end

    test "a check run in a nested shell after an edit is not read, so the turn is not learned" do
      for cmd <- [
            "bash -lc 'pytest -q' || true",
            "bash -c 'pytest -q' 2>&1 | tail -3",
            "sh -c 'pytest -q' && echo done",
            ~s{node -e "require('child_process').execSync('pytest -q')"}
          ] do
        state = heard_turn([edited("/r/a.py"), command(cmd, "1 failed in 0.02s", "completed")])
        refute TokenEconomizer.learns?(state.turns["a"], true), cmd
      end

      # The script of a command run whole as `bash -lc '<script>'` is read.
      state =
        heard_turn([edited("/r/a.py"), command("bash -lc 'pytest -q'", "1 passed in 0.02s")])

      assert TokenEconomizer.learns?(state.turns["a"], true)
    end

    test "a runner with any flags, an expansion or a substitution it reads is learned from" do
      for cmd <- [
            "bun test --coverage",
            "deno test --allow-read",
            "node --experimental-vm-modules node_modules/.bin/jest",
            "ruby -Itest test/a_test.rb",
            "pytest -q ${PYTEST_ARGS:-} \"$@\"",
            "pytest -q $(git ls-files 'test_*.py')",
            "cd \"$(git rev-parse --show-toplevel)\" && npm test",
            "source .venv/bin/activate && pytest -q",
            "pytest -q  # don't stop at the first failure",
            "pytest -q # $(",
            "pytest -q a#b.py",
            "cat <<'EOF' > /dev/null\nhi\nEOF\npytest -q"
          ] do
        state = heard_turn([edited("/r/a.py"), command(cmd, "1 passed in 0.02s")])
        assert TokenEconomizer.learns?(state.turns["a"], true), cmd
      end
    end

    test "a script a command runs that this does not read hides its check from learning" do
      for cmd <- [
            "echo $(bash -c 'pytest -q')",
            "x=`sh -c 'pytest -q'`; echo ok",
            "diff <(python3 -c 'import os; os.system(\"pytest\")') /dev/null",
            "python3 <<'EOF'\nimport os; os.system('pytest -q')\nEOF",
            "cat run.sh | bash",
            "eval \"$CHECK\"",
            "perl -le 'system q(pytest)'",
            "deno eval 'Deno.exit(0)'",
            "timeout 60 node --input-type commonjs -e 'x()'",
            ~s{node -r ./setup.js -e 'require("child_process").execSync("npm test")'},
            "node --require ts-node/register -e 'x()'",
            ~s{php -r 'system("vendor/bin/phpunit");'},
            "node a.js -e 'x()'",
            "source run.sh",
            ". ./run.sh && echo ok",
            "bash run.sh || true",
            "echo $(bash -c 'pytest -q') # don't",
            "mise exec -- node -e 'x()'",
            "mise x python@3.12 -- python -c 'x()'",
            "uv run python -c 'x()'",
            "poetry run bash -c 'pytest -q'",
            "npx node -e 'x()'",
            "env CI=1 nice -n 5 node -e 'x()'",
            # An escaped space keeps the `#` in its word, as the shell reads it.
            ~S{pytest a\ #$(bash -c 'pytest -q')},
            # A backslash in a comment continues no line: the next is a command.
            "pytest -q # note \\\nbash -c 'pytest -q'"
          ] do
        state =
          heard_turn([edited("/r/run.sh"), command(cmd, "1 failed in 0.02s", "completed")])

        refute TokenEconomizer.learns?(state.turns["a"], true), cmd
      end

      # A script written before this turn is the project's, run as any program is.
      state = heard_turn([edited("/r/a.py"), command("bash run.sh", "1 passed in 0.02s")])
      assert TokenEconomizer.learns?(state.turns["a"], true)
    end

    test "a check after every script in its passing && chain is its last word; one before a script is not" do
      for {cmd, learns} <- [
            {"bash run.sh && pytest -q", true},
            {"bash run.sh && echo ok && pytest -q && echo done", true},
            # The script ran after the check, and may have undone it or failed a check of
            # its own unread.
            {"pytest -q && bash run.sh", false},
            {"bash run.sh && pytest -q && bash run.sh", false},
            # Not one && chain: a script's failure need not stop the check.
            {"bash run.sh; pytest -q", false},
            {"bash run.sh || pytest -q", false},
            # A comment could hide where the chain ends.
            {"bash run.sh # && pytest -q", false}
          ] do
        state =
          heard_turn([edited("/r/run.sh"), command(cmd, "1 passed in 0.02s", "completed")])

        assert TokenEconomizer.learns?(state.turns["a"], true) == learns, cmd
      end

      # A chain that did not exit 0 says nothing of what the script did.
      state =
        heard_turn([
          edited("/r/run.sh"),
          command("bash run.sh && pytest -q", "1 passed in 0.02s", "failed", %{"exitCode" => 1})
        ])

      refute TokenEconomizer.learns?(state.turns["a"], true)
    end

    test "a check after an eval or a sourced script the turn wrote, in the same shell, is not its last word" do
      # `run.sh` may define `pytest() { echo '1 passed'; }`: sourced or eval'd, it runs in
      # the shell the check then runs in, so the check that follows may be its own.
      for {cmd, learns} <- [
            {". ./run.sh && pytest -q", false},
            {"source run.sh && pytest -q", false},
            {"source run.sh && echo ok && pytest -q", false},
            {~s{eval "$CHECK" && bash run.sh && pytest -q}, false},
            {~s{source "$SETUP" && bash run.sh && pytest -q}, false},
            # A function the command defines is not read either, whatever its body's form.
            {"pytest() { echo '1 passed'; } && bash run.sh && pytest -q", false},
            {"pytest() ( echo '1 passed' ) && bash run.sh && pytest -q", false},
            {"pytest () ( echo '1 passed' ) && bash run.sh && pytest -q", false},
            {"function pytest { echo 1 passed; } && bash run.sh && pytest -q", false},
            {"function pytest ( echo 1 passed ) && bash run.sh && pytest -q", false},
            # A body with no brackets: `[[ 1 ]]` makes `pytest` succeed.
            {"function pytest [[ 1 ]] && bash run.sh && pytest -q", false},
            {"function pytest [[ 1 ]] && pytest -q", false},
            # A group's `;` already cuts the `&&` chain; pinned so the group stays unread.
            {"{ function pytest [[ 1 ]]; } && bash run.sh && pytest -q", false},
            {"{ pytest() [[ 1 ]]; } && bash run.sh && pytest -q", false},
            # Only a simple command runs apart from the check: a builtin that may change what
            # `pytest` runs is not one, nor is a bare assignment.
            {"hash -p /bin/true pytest && bash run.sh && pytest -q", false},
            {"export PATH=./bin:$PATH && bash run.sh && pytest -q", false},
            {"printf -v PATH %s ./bin && bash run.sh && pytest -q", false},
            # An expansion assigns in the chain's own shell, quoted or not.
            {~s|: "${PATH:=./bin}" && bash run.sh && pytest -q|, false},
            {~s|echo "$((PATH=1))" && bash run.sh && pytest -q|, false},
            # A `cd` changes which file any path names, and which config a runner reads,
            # whatever the check's words: one after it is not read.
            {"cd web && bash run.sh && ./bin/test", false},
            {"cd web && bash run.sh && pytest ./tests", false},
            {"cd web && bash run.sh && pytest tests", false},
            {"cd web && bash run.sh && pytest tests/test_a.py", false},
            {"cd web && bash run.sh && pytest -q", false},
            {"cd web && FOO=1 bash run.sh && pytest -q", false},
            {"pushd web && bash run.sh && bin/pytest -q", false},
            {"popd && bash run.sh && pytest tests", false},
            {"PATH=./bin && bash run.sh && pytest -q", false},
            {"set -f && bash run.sh && pytest -q", false},
            {~s{"$RUN" && bash run.sh && pytest -q}, false},
            # A file the turn did not write sources nothing it changed, and a program or an
            # assignment to a program's environment runs apart.
            {". venv/bin/activate && bash run.sh && pytest -q", true},
            {"FOO=1 bash run.sh && pytest tests", true},
            {"./run.sh && echo ok && pytest -q", true}
          ] do
        state =
          heard_turn([edited("/r/run.sh"), command(cmd, "1 passed in 0.02s", "completed")])

        assert TokenEconomizer.learns?(state.turns["a"], true) == learns, cmd
      end
    end

    test "a command heard only in part after an edit is not read, so the turn is not learned" do
      capped = "cat > a.py <<'EOF'\n" <> String.duplicate("x = 1\n", 700) <> "EOF\npytest -q"
      failing = command(capped, "1 failed in 0.02s", "failed", %{"exitCode" => 1})

      state = heard_turn([edited("/r/a.py"), failing])
      refute TokenEconomizer.learns?(state.turns["a"], true)

      # An edit after it is the turn's last, and a check that passed after that is read.
      passing = command("pytest -q", "1 passed in 0.02s")
      state = heard_turn([edited("/r/a.py"), failing, edited("/r/a.py"), passing])
      assert TokenEconomizer.learns?(state.turns["a"], true)
    end

    test "a heredoc operator quoted, escaped or in a comment opens no heredoc" do
      for line <- [
            "printf '%s\\n' '<<EOF'",
            ~s{echo "<<EOF"},
            "echo \\<<EOF",
            "echo 'a\n<<EOF'",
            "# cat <<EOF",
            "true # <<EOF"
          ] do
        cmd = line <> "\npytest -q"
        assert Turn.status_of_tests(cmd) == "own", cmd

        failing = heard_turn([edited("/r/a.py"), command(cmd, "1 failed in 0.02s", "failed")])
        assert failing.turns["a"].guard.last_verify_failed, cmd
        refute TokenEconomizer.learns?(failing.turns["a"], true), cmd

        passing = heard_turn([edited("/r/a.py"), command(cmd, "1 passed in 0.02s")])
        assert TokenEconomizer.learns?(passing.turns["a"], true), cmd
      end

      # One opened after a quoted line, or on a line a quote spans, is read after that line.
      cmd = "echo '<<A'; cat <<B\npytest -q\nB\npytest -q"
      assert ShellEdits.split_heredocs(cmd) == {"echo '<<A'; cat <<B\npytest -q", ["pytest -q"]}
      cmd = "echo 'a\nb' <<B\nbody\nB\npytest -q"
      assert ShellEdits.split_heredocs(cmd) == {"echo 'a\nb' <<B\npytest -q", ["body"]}
    end

    test "a heredoc left open after an edit is not placed, so the turn is not learned" do
      cmd = "cat > notes.txt <<EOF\nx = 1\npytest -q"
      state = heard_turn([edited("/r/a.py"), command(cmd, "1 failed in 0.02s", "failed")])
      refute TokenEconomizer.learns?(state.turns["a"], true)
    end

    test "a turn's end stops its judge job, and off stops every judge job; a delivery under way finishes" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> observe(started("a")) |> observe(started("b"))
      {judge, state} = sleeper(state, "a", :judge)
      {delivery, state} = sleeper(state, "b", :delivery)

      state =
        observe(state, %{
          "type" => "turn.finished",
          "threadId" => "a",
          "runId" => "run-a",
          "status" => "completed"
        })

      assert_receive {:DOWN, _, :process, ^judge, _}
      assert Process.alive?(delivery)

      {:reply, :ok, state} =
        TokenEconomizer.handle_call({:settings, %{"loopGuard" => "watch"}}, nil, state)

      {judge, state} = sleeper(state, "b", :judge)

      {:reply, :ok, state} =
        TokenEconomizer.handle_call({:settings, %{"loopGuard" => "off"}}, nil, state)

      assert_receive {:DOWN, _, :process, ^judge, _}
      assert Process.alive?(delivery)
      assert Map.values(state.tasks) == [{"b", :delivery}] and state.turns == %{}
    end

    # The steer may already have been taken when the mode changes: what the delivery
    # answers is what happened.
    test "a redirect on its way when watching starts lands as its delivery says" do
      {delivery, state} = sleeper(redirecting("a"), "a", :delivery)

      {:reply, :ok, state} =
        TokenEconomizer.handle_call({:settings, %{"loopGuard" => "watch"}}, nil, state)

      assert Process.alive?(delivery)
      assert state.turns["a"].guard.redirecting

      state = delivered(state, "a", {:ok, %{}})
      guard = state.turns["a"].guard
      refute guard.redirecting
      assert guard.segment == 1 and guard.redirects == 1
      assert [%{"action" => "nudge", "delivered" => true}] = state.recent
    end
  end

  describe "the micro-skills at the plugin's seam" do
    # What was staged is kept on disk, read as the plugin starts: each test
    # starts with none.
    setup do
      File.rm(TokenEconomizer.staged_path())
      on_exit(fn -> File.rm(TokenEconomizer.staged_path()) end)
      on_exit(fn -> File.rm(TokenEconomizer.micro_skills_path("seam")) end)
    end

    defp settings(state, settings) do
      {:reply, :ok, state} = TokenEconomizer.handle_call({:settings, settings}, nil, state)
      state
    end

    @pytest "form_repair:run_tests:pytest"

    # A fact the project has learned: the bare `pytest` is missing here, and
    # `python -m pytest` works.
    defp learned(state) do
      skills =
        EnvFacts.add_candidate(EnvFacts.new(), %{
          id: @pytest,
          family: "form_repair",
          high: false,
          drift: false,
          params: %{
            "intent" => "run_tests",
            "a" => "pytest",
            "b_counts" => %{"python -m pytest" => 3},
            "error_counts" => %{}
          }
        })

      put_in(state.skills["seam"], skills)
    end

    defp stage(state, thread, instance, ids) do
      %{
        state
        | staged: Map.put(state.staged, {thread, instance}, ids),
          staged_order: state.staged_order ++ [{thread, instance}]
      }
    end

    # One turn of `thread` on `instance` that runs the tests the working way,
    # `calls` times.
    defp ran_tests(state, thread, instance, calls \\ 1) do
      run = "run-#{System.unique_integer([:positive])}"
      at = %{"threadId" => thread, "runId" => run}

      ran =
        Map.merge(at, %{
          "type" => "turn.item",
          "itemType" => "command_execution",
          "status" => "completed",
          "input" => "python -m pytest -q",
          "output" => "3 passed in 0.10s"
        })

      state =
        observe(
          state,
          started(thread, %{"runId" => run, "projectId" => "seam", "instanceId" => instance})
        )

      state = Enum.reduce(1..calls, state, fn _, state -> observe(state, ran) end)
      observe(state, Map.merge(at, %{"type" => "turn.finished", "status" => "completed"}))
    end

    # How often the fact counted as given and doing its work.
    defp fired(state), do: state.skills["seam"].facts[@pytest].life.fire_num

    test "a fold credits the facts staged for the conversation's own instance" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()
      state = stage(state, "t", "claude-work", [@pytest])

      # Another account of the same driver holds another conversation.
      state = ran_tests(state, "t", "claude-home")
      assert fired(state) == 0

      state = ran_tests(state, "t", "claude-work")
      assert fired(state) == 1
    end

    test "a proposal's spend is the project's, whatever its answer and the mode it arrives in" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "on"}) |> learned()
      state = put_in(state.skills["seam"].proposer, %Distiller{})
      usage = %{"inputTokens" => 100, "outputTokens" => 20}

      answer = fn state, result ->
        {:noreply, state} = TokenEconomizer.handle_info({:proposed, "seam", result}, state)
        state
      end

      # A reply that is not the facts asked for, then one arriving after the
      # proposer was turned off, then a call that failed.
      state = answer.(state, {:ok, %{"payload" => "not json"}, usage})
      assert state.skills["seam"].proposer.tokens == 120

      state = state |> settings(%{"microSkills" => "envfacts"})
      state = answer.(state, {:ok, %{"payload" => "{}"}, usage})
      state = answer.(state, {:error, "the model is unavailable"})

      assert state.skills["seam"].proposer.tokens == 240
      assert state.stats["proposerTokens"] == 240
      assert state.stats["proposerReplies"] == 3
    end

    test "a project's change publishes that project's entry alone, on its own topic" do
      project = "seam-#{System.unique_integer([:positive])}"
      on_exit(fn -> File.rm(TokenEconomizer.micro_skills_path(project)) end)

      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()
      state = put_in(state.skills[project], state.skills["seam"])

      # The test stands in for the plugin host, which publishes what it is cast.
      Process.register(self(), HalC2.Plugins)
      topic = "microSkills:#{project}"

      {:reply, {:ok, _view}, _state} =
        TokenEconomizer.handle_call(
          {:micro_skill_drop, %{"projectId" => project, "id" => @pytest}},
          nil,
          state
        )

      assert_receive {:"$gen_cast", {:publish, "token-economizer", ^topic, entry}}
      assert entry["projectId"] == project
      assert entry["dropped"] == [@pytest]
      refute_received {:"$gen_cast", {:publish, "token-economizer", "microSkills", _}}
    end

    test "what a conversation was staged outlives a restart, and an unreadable file is none" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()
      state = stage(state, "t", "claude-work", [@pytest])
      {:noreply, ^state} = TokenEconomizer.handle_continue(:save_staged, state)

      # The MC restarts; the conversation is resumed, so it is not staged again.
      {:ok, again} = TokenEconomizer.init(%{})
      assert {again.staged, again.staged_order} == {state.staged, state.staged_order}

      again = again |> settings(%{"microSkills" => "envfacts"}) |> learned()
      assert again |> ran_tests("t", "claude-work") |> fired() == 1

      File.write!(TokenEconomizer.staged_path(), "{not json")
      {:ok, again} = TokenEconomizer.init(%{})
      assert {again.staged, again.staged_order} == {%{}, []}
    end

    test "a settings save keeps what the projects learned and gives it the new caps" do
      {:ok, state} = TokenEconomizer.init(%{})
      # Learned in memory only: its save failed, or it was never due.
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()

      state = settings(state, %{"microSkills" => "envfacts", "loopGuardLevel" => "strict"})
      assert Map.has_key?(state.skills["seam"].facts, @pytest)

      state = settings(state, %{"microSkills" => "envfacts", "microSkillsMaxFacts" => 2})
      assert Map.has_key?(state.skills["seam"].facts, @pytest)
      assert state.skills["seam"].max_facts == 2

      state = settings(state, %{"microSkills" => "envfacts"})
      assert state.skills["seam"].max_facts == EnvFacts.max_facts()
    end

    test "the guard switched off under a judge job awaits its verdict no more" do
      {:ok, state} = TokenEconomizer.init(%{"microSkills" => "envfacts"})
      state = observe(state, started("a"))
      {judge, state} = sleeper(state, "a", :judge)
      pending = %{"id" => "a:0:1", "since" => System.monotonic_time(:second), "segment" => 0}
      state = update_in(state.turns["a"].guard, &%{&1 | judge_pending: pending, judge_calls: 1})

      state = settings(state, %{"loopGuard" => "off", "microSkills" => "envfacts"})
      assert_receive {:DOWN, _, :process, ^judge, _}
      assert Map.has_key?(state.turns, "a")
      assert state.turns["a"].guard.judge_pending == nil

      # What the job sent before it stopped comes late: paid for, but read by no one.
      verdict = %{"stuck" => true, "confidence" => 0.95, "reason" => "loop", "_tokens" => 5}

      {:noreply, state} =
        TokenEconomizer.handle_info({:verdict, "a", "run-a", "a:0:1", verdict}, state)

      assert state.turns["a"].guard.judge_arrived == nil
      assert state.stats["judgeTokens"] == 5

      # Switched on again, the guard asks afresh, not after the old job goes stale. A
      # settings save reads the envelopes afresh: the project has learned its turns.
      state = settings(state, %{"microSkills" => "envfacts"})
      saved = %{"level" => "default", "resolved_turns" => List.duplicate(30, 5)}
      state = put_in(state.trackers[{"p", "claudeAgent"}], Envelope.new("default", %{}, saved))
      state = stuck_until(state, &(&1.stats["judgeCalls"] > 0))
      assert state.stats["judgeCalls"] == 1
      assert [{_, {"a", :judge}}] = Map.to_list(state.tasks)
    end

    test "a conversation replaced while learning is off is credited none of its predecessor's facts" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()
      state = stage(state, "t", "claude-work", [@pytest])
      run = %{"threadId" => "t", "projectId" => "seam", "instanceId" => "claude-work"}
      future = System.monotonic_time(:millisecond) + 60_000

      # A Handoff replaces the conversation while learning is off: it is given nothing.
      state = settings(state, %{"microSkills" => "off"})

      {:reply, nil, state, {:continue, :save_staged}} =
        TokenEconomizer.handle_call({:shape_run, run, future}, nil, state)

      assert state.staged[{"t", "claude-work"}] == []

      state = settings(state, %{"microSkills" => "envfacts"})
      assert state |> ran_tests("t", "claude-work") |> fired() == 0
    end

    test "a turn is credited what its own conversation was staged, however late it folds" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()
      state = stage(state, "t", "claude-work", [@pytest])
      at = %{"threadId" => "t", "runId" => "run-old"}

      state =
        observe(
          state,
          started("t", %{
            "runId" => "run-old",
            "projectId" => "seam",
            "instanceId" => "claude-work"
          })
        )

      # A replacement past its deadline is given nothing before the old turn ends.
      run = %{"threadId" => "t", "projectId" => "seam", "instanceId" => "claude-work"}
      past = System.monotonic_time(:millisecond) - 1

      {:reply, nil, state, {:continue, :save_staged}} =
        TokenEconomizer.handle_call({:shape_run, run, past}, nil, state)

      assert state.staged[{"t", "claude-work"}] == []

      ran =
        Map.merge(at, %{
          "type" => "turn.item",
          "itemType" => "command_execution",
          "status" => "completed",
          "input" => "python -m pytest -q",
          "output" => "3 passed in 0.10s"
        })

      state = observe(state, ran)
      state = observe(state, Map.merge(at, %{"type" => "turn.finished", "status" => "completed"}))
      assert fired(state) == 1
    end

    # The thread is read back whole (the feature's "A turn whose end the feed lost is learned
    # from the thread's history"); here there is no thread to read, so nothing is learned.
    test "a turn the sweep drops learns nothing from what was heard of it" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = state |> settings(%{"microSkills" => "envfacts"}) |> learned()
      state = stage(state, "t", "claude-work", [@pytest])
      at = %{"threadId" => "t", "runId" => "run-cut"}

      state =
        observe(
          state,
          started("t", %{
            "runId" => "run-cut",
            "projectId" => "seam",
            "instanceId" => "claude-work"
          })
        )

      looked =
        Map.merge(at, %{
          "type" => "turn.item",
          "itemType" => "command_execution",
          "status" => "completed",
          "input" => "ls",
          "output" => "tests"
        })

      # Its last call, the test run the fact is for, and its end are lost.
      state = observe(state, looked)
      before = state.skills["seam"]
      state = %{state | active?: fn _thread, run -> run != "run-cut" end}
      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      {:noreply, state} = TokenEconomizer.handle_info(:sweep, state)
      Process.cancel_timer(state.sweep)

      refute Map.has_key?(state.turns, "t")
      assert state.skills["seam"] == before
    end

    test "with the guard off a settings save keeps the turns learning hears" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"loopGuard" => "off", "microSkills" => "envfacts"})
      state = observe(state, started("a"))

      state =
        settings(state, %{
          "loopGuard" => "off",
          "microSkills" => "envfacts",
          "microSkillsMaxFacts" => 4
        })

      assert Map.has_key?(state.turns, "a")
      refute state.turns["a"].partial
      # The guard watches nothing while it is off.
      assert TokenEconomizer.status(state)["watching"] == 0

      # Switched on under the turn, it folded none of its calls so far.
      state = settings(state, %{"microSkills" => "envfacts"})
      assert state.turns["a"].partial
      assert TokenEconomizer.status(state)["watching"] == 1
    end

    test "a turn longer than its buffer is read back whole, and the guard hears all of it" do
      {:ok, state} = TokenEconomizer.init(%{"loopGuard" => "watch"})
      state = settings(state, %{"loopGuard" => "watch", "microSkills" => "envfacts"})
      state = observe(state, started("a"))
      at = %{"type" => "turn.item", "threadId" => "a", "runId" => "run-a"}

      item =
        Map.merge(at, %{
          "itemType" => "command_execution",
          "status" => "completed",
          "input" => "ls",
          "output" => "a.py"
        })

      state = Enum.reduce(1..300, state, fn _, state -> observe(state, item) end)
      assert state.turns["a"].calls == :history
      assert state.turns["a"].guard.cum_turns == 300
      refute state.turns["a"].partial
    end

    test "switching learning under a turn leaves it partial, and only then" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"microSkills" => "envfacts"})
      state = observe(state, started("a"))
      refute state.turns["a"].partial

      state = settings(state, %{"microSkills" => "envfacts", "loopGuardLevel" => "strict"})
      refute state.turns["a"].partial

      state = settings(state, %{"microSkills" => "off"})
      assert state.turns["a"].partial
    end

    test "staging is keyed by the conversation, and nothing stages past its deadline" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"microSkills" => "envfacts"})
      future = System.monotonic_time(:millisecond) + 60_000
      past = System.monotonic_time(:millisecond) - 1

      run = %{"threadId" => "t", "projectId" => "p", "instanceId" => "claudeAgent"}

      {:reply, nil, state} =
        TokenEconomizer.handle_call({:shape_run, run, past}, nil, state)

      assert state.staged == %{}

      {:reply, nil, state, {:continue, :save_staged}} =
        TokenEconomizer.handle_call({:shape_run, run, future}, nil, state)

      other = %{run | "instanceId" => "codex"}

      {:reply, nil, state, {:continue, :save_staged}} =
        TokenEconomizer.handle_call({:shape_run, other, future}, nil, state)

      # Another account of the same driver is another conversation.
      account = Map.merge(run, %{"instanceId" => "claude-work", "provider" => "claudeAgent"})

      {:reply, nil, state, {:continue, :save_staged}} =
        TokenEconomizer.handle_call({:shape_run, account, future}, nil, state)

      assert Map.keys(state.staged) |> Enum.sort() ==
               [{"t", "claude-work"}, {"t", "claudeAgent"}, {"t", "codex"}]
    end

    test "a stored micro-skills mode that is not a choice is off" do
      {:ok, state} = TokenEconomizer.init(%{})
      future = System.monotonic_time(:millisecond) + 60_000
      run = %{"threadId" => "t", "projectId" => "p", "instanceId" => "claudeAgent"}

      for mode <- ["envfact", "disabled", true] do
        state = settings(state, %{"microSkills" => mode})

        assert {:reply, nil, %{staged: staged}} =
                 TokenEconomizer.handle_call({:shape_run, run, future}, nil, state)

        assert staged == %{}
      end
    end

    test "staging keeps the latest 128 conversations" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"microSkills" => "envfacts"})
      future = System.monotonic_time(:millisecond) + 60_000

      state =
        Enum.reduce(1..130, state, fn n, state ->
          run = %{"threadId" => "t#{n}", "projectId" => "p", "instanceId" => "codex"}

          {:reply, nil, state, {:continue, :save_staged}} =
            TokenEconomizer.handle_call({:shape_run, run, future}, nil, state)

          state
        end)

      assert length(state.staged_order) == 128
      assert hd(state.staged_order) == {"t3", "codex"}
      assert Map.keys(state.staged) |> Enum.sort() == Enum.sort(state.staged_order)
    end

    test "a saved fact that holds a credential leaves the project's file" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"microSkills" => "envfacts"})
      path = TokenEconomizer.micro_skills_path("seam")
      File.mkdir_p!(Path.dirname(path))

      leaky = %{
        "id" => "env_value:DB_PASS",
        "family" => "env_value",
        "params" => %{"var" => "DB_PASS", "good" => %{"hunter2" => 2}},
        "life" => %{}
      }

      File.write!(path, JSON.encode!(%{"facts" => %{"env_value:DB_PASS" => leaky}}))

      run = %{"threadId" => "t", "projectId" => "seam", "instanceId" => "codex"}
      future = System.monotonic_time(:millisecond) + 60_000

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          TokenEconomizer.handle_call({:shape_run, run, future}, nil, state)
        end)

      refute File.read!(path) =~ "hunter2"
      # The drop leaves a trace, and the trace no credential.
      assert log =~ "dropped 1 saved micro-skill fact(s) of project seam"
      assert log =~ ~s("env_value" => 1)
      refute log =~ "hunter2"
    end

    test "a run naming no conversation stages nothing" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"microSkills" => "envfacts"})
      future = System.monotonic_time(:millisecond) + 60_000

      for run <- [
            %{"projectId" => "p", "instanceId" => "claudeAgent"},
            %{"projectId" => "p", "threadId" => "t"},
            %{"projectId" => "p", "threadId" => 7, "provider" => "codex"}
          ] do
        {:reply, nil, after_run} =
          TokenEconomizer.handle_call({:shape_run, run, future}, nil, state)

        assert after_run.staged == %{}
      end
    end

    test "a drop that cannot be saved is refused, and the plugin stands" do
      {:ok, state} = TokenEconomizer.init(%{})
      state = settings(state, %{"microSkills" => "envfacts"})

      skills =
        EnvFacts.add_candidate(EnvFacts.new(), %{
          id: "form_repair:run_tests:pytest",
          family: "form_repair",
          high: false,
          drift: false,
          params: %{
            "intent" => "run_tests",
            "a" => "pytest",
            "b_counts" => %{},
            "error_counts" => %{}
          }
        })

      state = put_in(state.skills["p"], skills)

      # The write's temp path is a directory: the save cannot land.
      tmp = TokenEconomizer.micro_skills_path("p") <> ".tmp"
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:reply, {:error, message}, state} =
               TokenEconomizer.handle_call(
                 {:micro_skill_drop,
                  %{"projectId" => "p", "id" => "form_repair:run_tests:pytest"}},
                 nil,
                 state
               )

      assert message =~ "could not be saved"
      assert Map.has_key?(state.skills["p"].facts, "form_repair:run_tests:pytest")
    end
  end
end
