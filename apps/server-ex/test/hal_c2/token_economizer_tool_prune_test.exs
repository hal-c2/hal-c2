# SPDX-License-Identifier: Apache-2.0
# Ported in part from tests/test_live_hooks.py (the evidence counts:
# test_ten_prompts_over_two_sessions_are_enough_and_one_sessions_are_not,
# test_five_sessions_are_enough_however_short,
# test_a_session_without_prompts_is_no_evidence,
# test_a_high_risk_tool_needs_three_times_the_prompts,
# test_a_protected_tool_is_never_left_out_and_a_rule_already_written_comes_back,
# test_tools_given_back_stay_back_until_named_again,
# test_a_pending_deny_list_is_dropped_once_toolprune_is_no_longer_auto,
# test_codex_proposes_capabilities_it_never_saw_used,
# test_codex_needs_the_full_evidence_before_proposing),
# tests/test_live_core.py
# (test_codex_capability_evidence_includes_the_models_own_exec_calls) and
# tests/test_status_explain.py (restored items are not waiting to be applied)
# (microsoft/TokenEconomizer@cb42207e3e09).

for file <- ~w(tool_prune_evidence),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerToolPruneTest do
  @moduledoc """
  Tool pruning's evidence and decisions (`ToolPrune.Evidence`) as plain functions:
  how much unused evidence proposes a tool, what is never proposed, the quiet wait
  before `auto` applies, restore and apply by name, and Codex's packages. The
  plugin process, `shape_run/2` and the MC are covered by
  `features/plugins/token-economizer-tool-prune.feature`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.TokenEconomizer.ToolPrune.Evidence, as: Prune

  @now 1_000_000

  defp cfg(settings \\ %{}), do: Prune.config(settings)

  defp fold(state, prompts, used, cfg) do
    segment(state, prompts, used, cfg, [])
  end

  defp fold_imported(state, prompts, cfg) do
    segment(state, prompts, [], cfg, imported: true)
  end

  defp segment(state, prompts, used, cfg, opts) do
    Prune.fold_segment(
      state,
      Prune.candidate_tools(state["unit"]),
      used,
      prompts,
      cfg,
      @now,
      opts
    )
  end

  defp sessions(state, prompts_list, used \\ [], cfg \\ cfg(%{"toolPrune" => "propose"})) do
    Enum.reduce(prompts_list, state, fn prompts, acc -> fold(acc, prompts, used, cfg) end)
  end

  test "the settings' defaults are upstream's numbers" do
    cfg = cfg()
    assert cfg["mode"] == "auto"

    assert {cfg["evidence"], cfg["min_sessions"], cfg["sessions"], cfg["quiet_minutes"]} ==
             {10, 2, 5, 60}
  end

  test "ten prompts over two sessions are enough, and one session's are not" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("tool") |> fold(10, [], propose)

    assert Prune.proposal(state, propose) == []
    assert state["streaks"]["Workflow"] == %{"sessions" => 1, "prompts" => 10}

    state = fold(state, 1, [], propose)
    assert "Workflow" in Prune.proposal(state, propose)
    assert "CronCreate" in Prune.proposal(state, propose)

    # Nine prompts never are, even spread out.
    nine = Prune.new("tool") |> sessions([5, 4], [], propose)
    assert Prune.proposal(nine, propose) == []

    # With min_sessions pinned to 1, ten prompts in one session are enough.
    one = cfg(%{"toolPrune" => "propose", "toolPruneMinSessions" => 1})
    state = Prune.new("tool") |> fold(10, [], one)
    assert "Workflow" in Prune.proposal(state, one)
  end

  test "five sessions are enough however short, and four are not" do
    propose = cfg(%{"toolPrune" => "propose"})
    four = Prune.new("tool") |> sessions([1, 1, 1, 1], [], propose)
    assert Prune.proposal(four, propose) == []

    five = fold(four, 1, [], propose)
    assert "Workflow" in Prune.proposal(five, propose)
  end

  test "a session without prompts is no evidence" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("tool") |> fold(4, [], propose) |> fold(0, [], propose)

    assert state["sessions"] == 1
    assert state["streaks"]["Workflow"] == %{"sessions" => 1, "prompts" => 4}

    # A segment heard only in part folds the same way (no prompts of evidence):
    # a use in it still resets the streak, its silences grow none.
    state = fold(state, 0, ["Workflow"], propose)
    assert state["sessions"] == 1
    assert state["streaks"]["Workflow"] == %{"sessions" => 0, "prompts" => 0}
    assert "Workflow" in state["used"]
  end

  test "a high-risk tool needs three times the prompts" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("tool") |> sessions([20, 9], [], propose)

    assert Prune.proposal(state, propose) |> Enum.sort() ==
             Enum.sort(Prune.candidate_tools("tool") -- ["NotebookEdit"])

    state = fold(state, 1, [], propose)
    assert "NotebookEdit" in Prune.proposal(state, propose)
  end

  test "a tool ever seen in use is never proposed, and its streak resets" do
    propose = cfg(%{"toolPrune" => "propose"})

    state =
      Prune.new("tool")
      |> sessions([5, 5], [], propose)
      |> fold(3, ["Workflow"], propose)
      |> sessions([10, 10, 10], [], propose)

    refute "Workflow" in Prune.proposal(state, propose)
    assert Prune.summary(state, propose)["tools"]["Workflow"]["state"] == "used"
  end

  test "protected tools, by name or the person's pattern, are never proposed and a written one comes back" do
    for tool <- ~w(Bash Read Edit WebFetch TaskCreate Agent) do
      assert Prune.protected?(tool, cfg())
      refute tool in Prune.candidate_tools("tool")
    end

    protect = cfg(%{"toolPrune" => "propose", "toolPruneProtect" => ["Cron*"]})
    state = Prune.new("tool") |> sessions([10, 10], [], protect)
    proposed = Prune.proposal(state, protect)
    assert "Workflow" in proposed
    refute "CronCreate" in proposed

    # Already off before it was protected: it comes back at the next fold.
    propose = cfg(%{"toolPrune" => "propose"})
    {state, applied, []} = Prune.apply_named(state, propose, ["CronCreate", "Workflow"])
    assert Enum.sort(applied) == ["CronCreate", "Workflow"]
    state = fold(state, 1, [], protect)
    assert Prune.denied(state, protect) == ["Workflow"]
    refute "CronCreate" in state["off"]
  end

  test "under propose nothing is off until applied; under off nothing is proposed" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("tool") |> sessions([1, 1, 1, 1, 1], [], propose)

    assert Prune.proposal(state, propose) != []
    assert Prune.denied(state, propose) == []
    assert state["pending"] == nil

    {state, _applied, []} = Prune.apply_named(state, propose, nil)
    assert Prune.denied(state, propose) != []

    off = cfg(%{"toolPrune" => "off"})
    assert Prune.proposal(state, off) == []
    assert Prune.denied(state, off) == []
  end

  test "tools given back stay back until named again" do
    auto = cfg(%{"toolPrune" => "auto", "toolPruneQuietMinutes" => 0})
    state = Prune.new("tool") |> sessions([1, 1, 1, 1, 1], [], auto)
    {state, applied} = Prune.apply_pending(state, auto, @now)
    assert "Workflow" in applied and "CronCreate" in applied

    {state, restored} = Prune.restore(state, nil)
    assert Enum.sort(restored) == Enum.sort(applied)
    assert Prune.denied(state, auto) == []

    # Still unused, still kept: more evidence changes nothing.
    state = sessions(state, [5, 5, 5], [], auto)
    {state, []} = Prune.apply_pending(state, auto, @now + 90_000)
    assert Prune.proposal(state, auto) == []
    assert Prune.summary(state, auto)["tools"]["Workflow"]["state"] == "kept"

    # Applying one by name is the one way back; the other stays kept.
    {state, ["Workflow"], []} = Prune.apply_named(state, auto, ["Workflow"])
    assert Prune.denied(state, auto) == ["Workflow"]
    assert state["kept"] == applied -- ["Workflow"]
  end

  # Regression: the Maude model found a tool applied by name, then used in a
  # conversation that had it loaded, staying off until that conversation folded --
  # and shaping another conversation without it meanwhile.
  test "a use is noted at once: a tool applied by name and then used comes back before any fold" do
    auto = cfg(%{"toolPrune" => "auto", "toolPruneQuietMinutes" => 0})
    {state, ["Workflow"], []} = Prune.apply_named(Prune.new("tool"), auto, ["Workflow"])
    assert Prune.denied(state, auto) == ["Workflow"]

    state = Prune.note_used(state, ["Workflow"], auto)
    assert Prune.denied(state, auto) == []
    assert state["off"] == []

    state = sessions(state, [10, 10, 10], [], auto)
    {state, applied} = Prune.apply_pending(state, auto, @now + 90_000)
    refute "Workflow" in applied
    refute "Workflow" in Prune.proposal(state, auto)
  end

  test "apply by name refuses a protected, a used and an unknown tool" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("tool") |> fold(2, ["Workflow"], propose)

    {state, [], refused} =
      Prune.apply_named(state, propose, ["Bash", "Workflow", "NoSuchTool"])

    assert Enum.sort(refused) == ["Bash", "NoSuchTool", "Workflow"]
    assert Prune.denied(state, propose) == []
  end

  test "auto waits for the quiet, applies after a day regardless, and drops its list when no longer auto" do
    auto = cfg(%{"toolPrune" => "auto", "toolPruneQuietMinutes" => 60})
    state = Prune.new("tool") |> sessions([1, 1, 1, 1, 1], [], auto)
    state = Prune.activity(state, @now)
    assert %{"items" => items, "since" => @now} = state["pending"]
    assert "Workflow" in items

    # Just folded: not quiet yet.
    {state, []} = Prune.apply_pending(state, auto, @now + 59 * 60)
    # An hour idle: applied.
    {waited, applied} = Prune.apply_pending(state, auto, @now + 60 * 60)
    assert "Workflow" in applied
    assert waited["pending"] == nil

    # A busy project still gets its list after a day.
    busy = Prune.activity(state, @now + 86_400)
    {_state, applied} = Prune.apply_pending(busy, auto, @now + 86_401)
    assert "Workflow" in applied

    # A turn under way holds the quiet path, but not the day cap: applying only
    # shapes the next conversation, so a turn whose end was never heard (or one
    # that runs a full day) cannot stall the list for good.
    {_state, []} = Prune.apply_pending(busy, auto, @now + 3_600, true)
    {_state, applied} = Prune.apply_pending(busy, auto, @now + 86_401, true)
    assert "Workflow" in applied

    # Turned to propose meanwhile: the held list is dropped, the proposal stays.
    propose = cfg(%{"toolPrune" => "propose"})
    {state, []} = Prune.apply_pending(state, propose, @now + 86_401)
    assert state["pending"] == nil
    assert "Workflow" in Prune.proposal(state, propose)
  end

  test "imported turns form a proposal auto alone does not act on" do
    auto = cfg(%{"toolPrune" => "auto"})
    state = Prune.new("tool") |> fold_imported(20, auto)
    state = fold_imported(state, 20, auto)

    assert "Workflow" in Prune.proposal(state, auto)
    assert state["pending"] == nil

    # Live turns enough on their own hold the list (the quiet still applies).
    state = sessions(state, [5, 5], [], auto)
    assert "Workflow" in state["pending"]["items"]
  end

  test "codex proposes the packages it never saw used, after the full evidence" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("capability")

    # The controller demotes collaboration quickly upstream; a person's sessions
    # still need ten prompts of evidence here.
    state = sessions(state, [3, 3, 3], [], propose)
    assert Prune.proposal(state, propose) == []

    state = fold(state, 1, ["image_media"], propose)
    state = fold(state, 2, [], propose)
    assert Prune.proposal(state, propose) == ["collaboration", "goals"]

    summary = Prune.summary(state, propose)
    assert summary["tools"]["image_media"]["state"] == "used"
    assert summary["tools"]["goals"]["loadedSessions"] == 5
    assert {summary["sessions"], summary["prompts"]} == {5, 12}
  end

  test "codex demotes at most two packages per session, and image/media needs its exposures" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("capability") |> fold(1, [], propose)
    assert Enum.sort(state["demoted"]) == ["collaboration", "goals"]

    # One loaded exposure is not image/media's three.
    state = fold(state, 1, [], propose)
    refute "image_media" in state["demoted"]
    state = fold(state, 1, [], propose)
    assert "image_media" in state["demoted"]
  end

  test "a single codex package use protects it for good" do
    propose = cfg(%{"toolPrune" => "propose"})

    state =
      Prune.new("capability")
      |> sessions([5, 5], ["collaboration"], propose)
      |> sessions([5, 5, 5], [], propose)

    refute "collaboration" in Prune.proposal(state, propose)
    refute "collaboration" in state["demoted"]
  end

  test "what an item used, by unit" do
    assert Prune.used_in_item(%{"tool" => "NotebookEdit", "itemType" => "file_change"}, "tool") ==
             ["NotebookEdit"]

    assert Prune.used_in_item(%{"itemType" => "command_execution"}, "tool") == ["Bash"]

    # Codex's own exec calls name the nested helper in the input.
    exec = %{
      "itemType" => "dynamic_tool",
      "tool" => "exec",
      "input" => "await tools.view_image({path: 'a.png'})"
    }

    assert Prune.used_in_item(exec, "capability") == ["image_media"]

    assert Prune.used_in_item(
             %{"tool" => "spawn_agent", "itemType" => "dynamic_tool"},
             "capability"
           ) ==
             ["collaboration"]

    assert Prune.used_in_item(
             %{"tool" => "update_goal", "itemType" => "dynamic_tool"},
             "capability"
           ) ==
             ["goals"]

    assert Prune.used_in_item(%{"itemType" => "command_execution"}, "capability") == []
    assert Prune.used_in_item(%{"tool" => "Anything"}, nil) == []
  end

  test "providers that turn off nothing get no proposals" do
    assert Prune.unit_for_provider("opencode") == nil
    assert Prune.unit_for_provider(nil) == nil
    assert Prune.candidate_tools(nil) == []
    state = Prune.new(nil) |> sessions([10, 10])
    assert Prune.proposal(state, cfg()) == []
  end

  test "each thread's last folded run is remembered as its watermark" do
    state = Prune.new("tool")
    assert Prune.seeded_run(state, "thread-a") == nil

    state = Prune.note_thread(state, "thread-a", "run-1")
    state = Prune.note_thread(state, "thread-b", "run-9")
    state = Prune.note_thread(state, "thread-a", "run-2")
    state = Prune.note_thread(state, "thread-a", nil)

    assert Prune.seeded_run(state, "thread-a") == "run-2"
    assert Prune.seeded_run(state, "thread-b") == "run-9"
  end

  test "restore refuses a proposed tool before it ever applies" do
    auto = cfg(%{"toolPrune" => "auto", "toolPruneQuietMinutes" => 0})
    state = Prune.new("tool") |> sessions([1, 1, 1, 1, 1], [], auto)
    assert "Workflow" in Prune.proposal(state, auto)

    {state, []} = Prune.restore(state, ["Workflow", "NoSuchTool"])
    assert state["kept"] == ["Workflow"]
    assert state["pending"] == nil or "Workflow" not in state["pending"]["items"]

    {state, applied} = Prune.apply_pending(state, auto, @now + 90_000)
    refute "Workflow" in applied
    refute "Workflow" in Prune.proposal(state, auto)
  end

  test "the state is its own JSON, round-tripped" do
    propose = cfg(%{"toolPrune" => "propose"})
    state = Prune.new("tool") |> sessions([10, 10], [], propose)
    {state, _applied, []} = Prune.apply_named(state, propose, ["Workflow"])

    round = state |> Prune.dump() |> JSON.encode!() |> JSON.decode!()
    assert Prune.new("tool", round) == Map.drop(state, [])
  end
end
