# SPDX-License-Identifier: Apache-2.0
# Ported in part from tests/test_loopguard_productive_turns.py and
# tests/test_config_integer_thresholds.py (microsoft/TokenEconomizer@cb42207e3e09).

for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge token_economizer),
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

  # Printed by Playwright on Windows as it exits, after a passing run as after a failing one.
  @libuv ~S"Assertion failed: !(handle->flags & UV_HANDLE_CLOSING), file src\win\async.c, line 76"

  test "the package reads, and its own defaults are settings it accepts" do
    dir = Path.expand("../../../../plugins/token-economizer", __DIR__)
    assert {:ok, manifest, sources, _hash} = HalC2.Plugins.Package.read(dir)
    assert manifest.id == "token-economizer"
    assert "token_economizer.ex" in Enum.map(sources, &Path.basename/1)

    defaults = Map.new(manifest.settings, &{&1.key, &1.default})
    assert :ok = TokenEconomizer.validate_settings(defaults)
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

      # The run checked the code before the edit after it, not the edit.
      cmd = "pytest -q && sed -i 's/a/b/' a.py"
      assert elem(Turn.fold(g, "Bash", %{"command" => cmd}, passing, 0, opts), 1) != nil

      # The edit before the run is what it checked.
      cmd = "sed -i 's/a/b/' a.py && pytest -q"
      assert {_, nil, nil} = Turn.fold(g, "Bash", %{"command" => cmd}, passing, 0, opts)
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

    test "after a restart, take every event the feed still holds as possibly before missed ones" do
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
      state = state |> observe(started("a")) |> observe(%{"type" => "noop"})
      state = observe(state, started("b"))
      assert state.turns["a"].partial and state.turns["b"].partial

      state = observe(state, started("c"))
      refute state.turns["c"].partial
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

      state =
        Enum.reduce_while(1..60, state, fn i, state ->
          item =
            if rem(i, 2) == 0,
              do: %{"itemType" => "file_change", "status" => "completed", "path" => "/r/a.py"},
              else:
                command("pytest -q", "FAILED t - AssertionError", "failed", %{"exitCode" => 1})

          state =
            observe(
              state,
              Map.merge(item, %{"type" => "turn.item", "threadId" => "a", "runId" => "run-a"})
            )

          if state.stats["judgeCalls"] > 0, do: {:halt, state}, else: {:cont, state}
        end)

      assert state.stats["judgeCalls"] == 1
      assert_receive {:DOWN, _, :process, ^old, _}
      assert [{_, {"a", :judge}}] = Map.to_list(state.tasks)
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

    test "a turn's end stops its judge job, watching stops deliveries, and off stops every task" do
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

      assert_receive {:DOWN, _, :process, ^delivery, _}
      assert state.tasks == %{}

      {judge, state} = sleeper(state, "b", :judge)

      {:reply, :ok, state} =
        TokenEconomizer.handle_call({:settings, %{"loopGuard" => "off"}}, nil, state)

      assert_receive {:DOWN, _, :process, ^judge, _}
      assert state.tasks == %{} and state.turns == %{}
    end
  end
end
