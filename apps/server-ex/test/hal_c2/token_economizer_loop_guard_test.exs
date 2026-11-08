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

    # Stopped before it finished: no status.
    assert {_, _, _, nil} = TokenEconomizer.call_of(command("npm test", "", "declined"))
    # The provider's own code wins.
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

    test "a judge job that never answers stops blocking the next one" do
      opts = [envelope: 30.0, thr: Rules.defaults(), judge: true, now: 0]
      {g, _} = stuck_turn(Turn.new("t"), 30, opts)
      assert %{"since" => 0} = g.judge_pending
      later = Keyword.put(opts, :now, Turn.judge_stale_s() + 1)
      {g, _} = stuck_turn(g, 12, later)
      assert g.judge_calls >= 2
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

      failing = fn _, _ -> {:error, "no model"} end
      assert %{"stuck" => nil} = Judge.run("digest", 0.7, failing)

      assert Rules.read_verdict(Judge.run("digest", 0.7, failing), Rules.defaults()) ==
               {false, "judge-ambiguous-spared"}
    end
  end
end
