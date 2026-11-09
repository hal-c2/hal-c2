# Sources:
#   plugins/token-economizer/mc/tool_prune_evidence.ex (the evidence, proposals, apply, restore)
#   plugins/token-economizer/mc/token_economizer.ex (hears turns, shape_run/2 and the uses it reads back first, the toolPrune topic and calls)
#   apps/server-ex/lib/hal_c2/orchestration/native_subagent.ex (a subagent's calls, heard as its parent turn's)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (a thread's history, which turns a subagent worked in)
#   plugins/token-economizer/plugin.json (toolPrune, toolPruneEvidence, toolPruneMinSessions, toolPruneSessions, toolPruneQuietMinutes, toolPruneProtect)
#   apps/server-ex/lib/hal_c2/orchestration/run_shape.ex (a conversation's tools, kept for the whole conversation)
#   microsoft/TokenEconomizer@cb42207e3e09 tokeneconomizer/toolprune/, tokeneconomizer/plugin/fold.py, denylist.py, adapter.py (what this ports)
#   hal-c2/hal-c2#1399 (the TokenEconomizer port)

@plugin-token-economizer
Feature: TokenEconomizer's tool pruning
  An agent's tool definitions are sent with every request, whether or not the
  project's work ever calls them. TokenEconomizer keeps count, per project and
  provider, of the tools a conversation had loaded and never used, over turns and
  conversations. Once that evidence is enough, the tool is proposed; under auto
  it is turned off by itself once the project has been quiet a while, and under
  propose only when the person applies it. Either way it takes effect from the
  next provider conversation, never during one. A protected work-surface tool or
  one ever seen in use is never proposed, and a tool the person gives back is
  never turned off again unless they apply it by name.

  Background:
    Given an MC running the TokenEconomizer plugin

  @mc
  Scenario: Under propose, an unused tool is turned off only once the person applies it, from the next conversation
    Given tool pruning only proposes
    And a project whose Claude had "CronCreate" loaded and unused for 5 sessions
    When a Claude thread in the project runs a turn
    Then Claude ran the turn with "CronCreate" available
    And tool pruning proposes "CronCreate" for the project
    When the person applies tool pruning's proposal for the project
    And another Claude thread in the project runs a turn
    Then Claude ran that turn without "CronCreate"
    And tool pruning lists "CronCreate" as off for the project

  @mc
  Scenario: A tool given back stays back
    Given a project where "CronCreate" is turned off for Claude
    When the person restores tool pruning's tools for the project
    And a Claude thread in the project runs a turn
    Then Claude ran the turn with "CronCreate" available
    And tool pruning lists "CronCreate" as kept for the project

  @mc
  Scenario: A tool that was used is refused even when applied by name
    Given a project whose Claude used "CronCreate"
    When the person applies "CronCreate" by name for the project
    Then "CronCreate" is refused
    And tool pruning lists nothing as off for the project

  @mc
  Scenario: Under auto, a held list is applied once the project has been quiet, at the next conversation
    Given a project whose Claude had "CronCreate" loaded and unused for 5 sessions, held for a quiet project
    When a Claude thread in the project runs a turn
    Then Claude ran the turn without "CronCreate"
    And tool pruning lists "CronCreate" as off for the project

  @mc
  Scenario: A tool used in turns the plugin missed counts as used, read back from the thread
    Given tool pruning folds a project's conversations as soon as it is quiet
    And a Claude thread in the project runs a turn
    And the plugin missed a turn of that thread in which Claude used "CronCreate"
    When that thread runs another turn
    Then tool pruning lists "CronCreate" as used for the project

  @mc
  Scenario: A tool used in a turn the plugin missed is not turned off for the next conversation, though the thread's conversation goes on
    Given a Claude thread in the project runs a turn
    And the person applies "CronCreate" by name for the project
    And the plugin missed a turn of that thread in which Claude used "CronCreate"
    And that thread runs another turn
    When another Claude thread in the project runs a turn
    Then Claude ran the turn with "CronCreate" available
    And tool pruning lists nothing as off for the project

  @mc
  Scenario: Turns the plugin missed in which a Claude subagent worked are no evidence a tool went unused
    Given tool pruning folds a project's conversations as soon as it is quiet
    And a Claude thread in the project runs a turn
    And the plugin missed a turn of that thread in which a Claude subagent worked
    When that thread runs another turn
    Then tool pruning counts all 3 turns, but at most the one it heard as leaving "CronCreate" unused

  @mc
  Scenario: A tool a Claude subagent used counts as used for the project
    Given tool pruning folds a project's conversations as soon as it is quiet
    When a Claude thread in the project runs a turn in which a subagent uses "CronCreate"
    Then tool pruning lists "CronCreate" as used for the project

  @mc
  Scenario: Applying a tool for a project that never ran is refused and keeps nothing for it
    When the person applies "CronCreate" by name for a project that never ran
    Then tool pruning answers that it has no evidence for that project
    And tool pruning keeps nothing for that project

  @backlog
  Scenario: The plugin's page shows what is off, proposed and kept, and lets the person apply and restore
    Given a project where "CronCreate" is turned off for Claude
    When the person opens TokenEconomizer's page
    Then the page shows "CronCreate" as off, with the evidence for it
    And the page offers to give it back
