# The plugin's MC modules are compiled when the plugin starts, not with the MC: compiled
# here to beams of their own, which keep the docs and source the coverage reads. The
# plugin's proofs share them, so they are compiled once per run, under a lock: test
# files load in parallel, and a second compile would remove the beams under the other
# file's tests.
beams = Path.join(Mix.Project.build_path(), "plugins/token-economizer")

:global.trans({:token_economizer_beams, self()}, fn ->
  unless :persistent_term.get(:token_economizer_beams, false) do
    "../../../../plugins/token-economizer/mc/*.ex"
    |> Path.expand(__DIR__)
    |> Path.wildcard()
    |> HalC2.Proof.compile_plugin(beams)

    :persistent_term.put(:token_economizer_beams, true)
  end
end)

Code.prepend_path(beams)

defmodule HalC2.TokenEconomizerToolPruneProofTest do
  # TokenEconomizer's tool pruning: one project and one candidate tool (the laws hold
  # tool by tool; the exact counters are the property test's in
  # prop/hal_c2/token_economizer_tool_prune_prop_test.exs, upstream's cases the plain
  # test's). Conversations start shaped, use the tool or not, and fold into the
  # evidence; the person applies, restores or refuses, and changes the mode; the
  # plugin restarts; the feed misses a use; the project goes quiet.
  #
  # Each part of the design is a switch in the model, and turning one off finds the
  # flaw it closes (each search takes well under a second):
  #
  #   - Without Safe, a protected tool, or one an agent used, is proposed and
  #     turned off by name.
  #   - Without Kept, a tool the person gave back, or refused while it was only
  #     proposed or held, is proposed again at the next fold and auto takes it away.
  #   - Without Frozen, applying a tool while a conversation runs changes that
  #     conversation's tools under way, and its prompt cache with them.
  #   - Without Gated, what auto held is applied under propose too, with nobody's
  #     say-so.
  #   - Without Quiet, auto applies the moment a proposal forms, while the
  #     project's conversations are still warm.
  #   - Without Capped, one fold demotes every Codex package at once.
  #   - Without Evid, a tool is proposed after a single unused conversation.
  #   - Without Persist, a restart forgets the tool was ever used (or given back),
  #     and it can be turned off after all.
  #   - Without Partial, a conversation whose use of the tool the feed missed folds
  #     as one that left it unused, and grows the streak that proposes it.
  @counts "the exact prompt and session counters and thresholds: prop/hal_c2/token_economizer_tool_prune_prop_test.exs and test/hal_c2/token_economizer_tool_prune_test.exs"
  @guard "the loop guard's, modelled in proof/hal_c2/token_economizer_loop_guard_proof_test.exs"

  use HalC2.Proof,
    model: "token_economizer_tool_prune.maude",
    module: "TOKEN-ECONOMIZER-TOOL-PRUNE",
    check: "TOKEN-ECONOMIZER-TOOL-PRUNE-PROPS",
    timeout: 600_000,
    code: [
      {:exports, HalC2Plugins.TokenEconomizer.ToolPrune.Evidence},
      {:exports, HalC2Plugins.TokenEconomizer},
      {:messages, HalC2Plugins.TokenEconomizer},
      {:state, HalC2Plugins.TokenEconomizer}
    ],
    covers: %{
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.config/1" => ~w(cfg mode),
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.candidate_tools/1" => "tool",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.protected?/2" => "allowed",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.enough_evidence?/4" => "propon",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.new/2" => "fresh",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.fold_segment/7" => ~w(finish folded fold2),
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.proposal/2" => "propon",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.denied/2" => ~w(shape-start begin),
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.apply_pending/4" =>
        ~w(auto-apply begin canAuto2),
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.apply_named/3" =>
        ~w(apply apply-name turnoff),
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.restore/2" => "restore",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.note_used/3" => "use",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.activity/2" => "quiet",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.used_in_item/2" => "use",
      "HalC2Plugins.TokenEconomizer handle_call {:settings, _}" => "settings",
      "HalC2Plugins.TokenEconomizer handle_call {:shape, _}" => "shape-start",
      "HalC2Plugins.TokenEconomizer handle_call {:toolprune, _, _}" =>
        ~w(apply apply-name restore),
      "HalC2Plugins.TokenEconomizer handle_call {:observe, _}" =>
        ~w(use prompt finish reread seg),
      "HalC2Plugins.TokenEconomizer state :missing" => "seg",
      "HalC2Plugins.TokenEconomizer handle_info {:toolprune_tick, _}" => ~w(auto-apply finish),
      "HalC2Plugins.TokenEconomizer state :settings" => ~w(cfg mode),
      "HalC2Plugins.TokenEconomizer state :prunes" => "tool",
      "HalC2Plugins.TokenEconomizer state :convs" => ~w(conv hearing),
      "HalC2Plugins.TokenEconomizer state :shaped" => "conv"
    },
    abstracts: %{
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.unit_for_provider/1" =>
        "which providers have candidates at all; the model has the one candidate, and other providers get no proposals, which the plain test checks",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.high_risk?/1" => @counts,
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.note_thread/3" =>
        "remembering each thread's last folded run so a restart folds only the runs after it; a restart stands for the missed turns here",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.unseen_runs/4" =>
        "which of a thread's earlier runs a restart folds, after the watermark's run or, when a rollback took it, its place; a restart stands for the missed turns here, and the plain test covers the watermark",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.new_conversation/2" =>
        "a conversation's segments count as one session, which is among " <> @counts,
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.seeded_run/2" =>
        "reading that watermark, which decides nothing here",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.dump/1" =>
        "the evidence as its JSON file keeps it; that it is kept at all is the Persist switch",
      "HalC2Plugins.TokenEconomizer.ToolPrune.Evidence.summary/2" =>
        "what the topic and the call carry, which decides nothing",
      "HalC2Plugins.TokenEconomizer handle_call :status" => @guard,
      "HalC2Plugins.TokenEconomizer handle_info {:verdict, _, _, _, _}" => @guard,
      "HalC2Plugins.TokenEconomizer handle_info {:delivered, _, _, _, _}" => @guard,
      "HalC2Plugins.TokenEconomizer handle_info {:DOWN, _, :process, _, _}" => @guard,
      "HalC2Plugins.TokenEconomizer state :sup" => @guard,
      "HalC2Plugins.TokenEconomizer state :tasks" => @guard,
      "HalC2Plugins.TokenEconomizer handle_info _" => "any other message is ignored",
      "HalC2Plugins.TokenEconomizer state :turns" => @guard,
      "HalC2Plugins.TokenEconomizer state :trackers" => @guard,
      "HalC2Plugins.TokenEconomizer state :seeded" =>
        "which threads' earlier turns were read back this run, or could not be yet (no fold then moves the watermark, which the plain test covers); their folds are imported, which differs only in the live streaks auto needs (the plain test covers it), and a restart stands for the missed turns here",
      "HalC2Plugins.TokenEconomizer state :prune_timers" =>
        "when the tick looks again; time passing is the wait rule",
      "HalC2Plugins.TokenEconomizer state :stats" => @guard,
      "HalC2Plugins.TokenEconomizer state :recent" => @guard,
      "HalC2Plugins.TokenEconomizer.status/1" => @guard,
      "HalC2Plugins.TokenEconomizer.prune_status/1" =>
        "what the toolPrune topic carries, which decides nothing",
      "HalC2Plugins.TokenEconomizer.envelope_path/1" => @guard,
      "HalC2Plugins.TokenEconomizer.toolprune_path/1" =>
        "where a project's evidence is kept; the model keeps it in tool",
      "HalC2Plugins.TokenEconomizer.call_of/1" => @guard
    },
    environment: %{
      "wait" => "no conversation under way and time passes, so the project has been quiet",
      "restart" => "the plugin's process stops and starts again with its saved settings",
      "miss" => "the feed misses a use of the tool, and says so with a later event"
    },
    scenarios: %{
      "plugins/token-economizer-tool-prune.feature" => [
        "Under propose, an unused tool is turned off only once the person applies it, from the next conversation",
        "A tool given back stays back",
        "A tool that was used is refused even when applied by name",
        "Under auto, a held list is applied once the project has been quiet, at the next conversation"
      ]
    }

  # Safe, Kept, Frozen, Gated, Quiet, Capped, Evid, Persist, Partial.
  @design "true, true, true, true, true, true, true, true, true"

  test "under auto, over three conversations, two of the person's actions and a use missed, no law is broken",
       %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, auto, false, 3, 2, 1)", "unsafe", [])
  end

  test "under propose the same holds", %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, propose, false, 3, 2, 1)", "unsafe", [])
  end

  test "a protected tool is never turned off", %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, auto, true, 2, 2, 0)", "unsafe", [])
  end

  test "conversations never get stuck", %{proof: proof} do
    refute_deadlock(proof, "start(#{@design}, auto, false, 2, 1, 1)", "over", [])
  end

  test "every conversation ends in the end", %{proof: proof} do
    assert_ltl(proof, "start(#{@design}, auto, false, 2, 1, 1)", "<> finished",
      fair: ~w(shape-start finish)
    )
  end
end
