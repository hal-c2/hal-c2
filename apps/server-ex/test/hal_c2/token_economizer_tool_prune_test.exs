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

  test "a conversation read back first still counts as a live session when it resumes" do
    auto = cfg(%{"toolPrune" => "auto"})
    state = Prune.new("tool")
    state = Enum.reduce(~w(a b), state, &segment(&2, 1, [], auto, imported: true, thread: &1))
    state = Enum.reduce(~w(a b), state, &segment(&2, 5, [], auto, thread: &1))

    assert state["sessions"] == 2
    assert state["liveStreaks"]["Workflow"] == %{"sessions" => 2, "prompts" => 10}
    assert "Workflow" in state["pending"]["items"]
  end

  test "auto applies none of what it held once live evidence no longer supports it" do
    low = cfg(%{"toolPrune" => "auto", "toolPruneQuietMinutes" => 0})
    state = Prune.new("tool") |> sessions([5, 5], [], low)
    assert "Workflow" in state["pending"]["items"]

    # Read back: the whole evidence is past the raised thresholds, the live is not.
    state = Enum.reduce(1..20, state, &segment(&2, 5, [], low, imported: true, thread: "#{&1}"))

    high =
      cfg(%{
        "toolPrune" => "auto",
        "toolPruneEvidence" => 50,
        "toolPruneSessions" => 20,
        "toolPruneQuietMinutes" => 0
      })

    assert "Workflow" in Prune.proposal(state, high)

    assert {%{"pending" => nil}, []} = Prune.apply_pending(state, high, @now + 60)
  end

  test "imported prompts of a conversation already counted are no live evidence auto acts on" do
    auto = cfg(%{"toolPrune" => "auto"})
    live = &segment(&1, 1, [], auto, thread: &2)
    state = Prune.new("tool") |> live.("a") |> live.("b")
    state = segment(state, 20, [], auto, imported: true, thread: "a")

    assert state["importedSessions"] == 0
    assert "Workflow" in Prune.proposal(state, auto)
    assert state["pending"] == nil
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

  test "codex's two demotions are per conversation, not per idle segment of one" do
    propose = cfg(%{"toolPrune" => "propose"})
    eligible = %{"collaboration" => 3, "goals" => 3, "image_media" => 3}
    segment = &segment(&1, 1, [], propose, thread: "a")

    state = Prune.new("capability", %{"loadedSessions" => eligible}) |> segment.() |> segment.()
    assert Enum.sort(state["demoted"]) == ["collaboration", "goals"]

    state = state |> Prune.new_conversation("a") |> segment.()
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

    # A direct call keeps Codex's namespace; an MCP server's tool of the same name is not
    # Codex's package.
    direct = &%{"itemType" => "dynamic_tool", "tool" => &1, "input" => ~s({"path":"a.png"})}
    assert Prune.used_in_item(direct.("tools.view_image"), "capability") == ["image_media"]
    assert Prune.used_in_item(direct.("files.view_image"), "capability") == []

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

  test "a restart folds a thread's runs after its watermark, whoever's that was, and only its provider's" do
    runs =
      for {id, provider} <- [a: "codex", b: "claudeAgent", c: "codex", d: "claudeAgent"],
          do: %{"runId" => "#{id}", "provider" => provider}

    claude? = &(&1["provider"] == "claudeAgent")

    # The watermark is a Codex run: the Claude runs before it are not folded again.
    assert {"d", [%{"runId" => "d"}]} = Prune.unseen_runs(runs, "c", nil, claude?)

    assert {"d", [%{"runId" => "b"}, %{"runId" => "d"}]} =
             Prune.unseen_runs(runs, nil, nil, claude?)

    # One no longer read back is older than all of them.
    assert {"d", [_, _]} = Prune.unseen_runs(runs, "gone", nil, claude?)
    # Nothing new keeps the watermark, and nothing of the provider's still moves it.
    assert {"d", []} = Prune.unseen_runs(runs, "d", nil, claude?)
    assert {"c", []} = Prune.unseen_runs(Enum.take(runs, 3), "b", nil, claude?)
    # The run starting, heard after it ended, and any after it are still to be heard.
    assert {"b", [%{"runId" => "b"}]} = Prune.unseen_runs(runs, nil, "c", claude?)
  end

  test "a conversation counts as one session however many idle segments it folds" do
    cfg =
      Prune.config(%{
        "toolPruneEvidence" => 1,
        "toolPruneMinSessions" => 2,
        "toolPruneSessions" => 2
      })

    loaded = Prune.candidate_tools("tool")
    fold = &Prune.fold_segment(&1, loaded, [], 1, cfg, 0, thread: "a")

    state = "tool" |> Prune.new() |> fold.() |> fold.() |> fold.()
    assert %{"sessions" => 1, "prompts" => 3} = state
    assert state["streaks"]["Workflow"] == %{"sessions" => 1, "prompts" => 3}
    assert Prune.proposal(state, cfg) == []

    # Its next conversation counts again, and the counting survives a restart.
    state = state |> Prune.new_conversation("a") |> fold.()
    assert state["sessions"] == 2
    assert "Workflow" in Prune.proposal(state, cfg)
    assert Prune.new("tool", JSON.decode!(JSON.encode!(state)))["countedThreads"] == ["a"]
  end

  test "auto drops what it held once the person raises the thresholds past it" do
    low =
      Prune.config(%{
        "toolPruneEvidence" => 1,
        "toolPruneMinSessions" => 1,
        "toolPruneSessions" => 1,
        "toolPruneQuietMinutes" => 0
      })

    high =
      Prune.config(%{
        "toolPruneEvidence" => 50,
        "toolPruneSessions" => 50,
        "toolPruneQuietMinutes" => 0
      })

    state =
      Prune.fold_segment(
        Prune.new("capability"),
        Prune.candidate_tools("capability"),
        [],
        1,
        low,
        0
      )

    assert %{"items" => [_ | _]} = state["pending"]
    assert "collaboration" in state["demoted"]

    assert {%{"pending" => nil, "off" => []}, []} = Prune.apply_pending(state, high, 10)
  end

  test "a Codex subagent the MC recorded is a use of collaboration" do
    assert Prune.used_in_item(%{"itemType" => "subagent", "status" => "running"}, "capability") ==
             ["collaboration"]

    assert Prune.used_in_item(%{"itemType" => "subagent"}, "tool") == []
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

  test "a saved file of the wrong shape is read as far as it has the right one" do
    saved = %{
      "streaks" => %{"Workflow" => 3, "CronCreate" => %{"sessions" => 2, "prompts" => "x"}},
      "liveStreaks" => ["Workflow"],
      "loadedSessions" => %{"Workflow" => "two", "CronList" => -4},
      "seededThreads" => %{"a" => 7},
      "sessions" => -1,
      "pending" => %{"items" => "Workflow"}
    }

    state = Prune.new("tool", saved)
    assert state["streaks"] == %{"CronCreate" => %{"sessions" => 2, "prompts" => 0}}
    assert state["liveStreaks"] == %{}
    assert state["loadedSessions"] == %{"Workflow" => 0, "CronList" => 0}
    assert state["sessions"] == 0
    assert state["pending"] == %{"items" => ["Workflow"], "since" => 0}

    # And it folds like any other.
    state = Prune.fold_segment(state, ["Workflow"], [], 3, cfg(), @now, thread: "a")
    assert state["streaks"]["Workflow"] == %{"sessions" => 1, "prompts" => 3}
  end
end
