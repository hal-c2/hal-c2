# Sources:
#   packages/contracts/src/settings.ts (NativeSubagents, nativeSubagents)
#   apps/server-ex/lib/hal_c2/settings.ex (hal_c2_subagents?)
#   apps/server-ex/lib/hal_c2/mcp.ex (instructions)
#   apps/desktop-qt/qml/HalC2/Bricks/js/settingsRows.js (the Subagents row)
#   apps/tui/src/host/sections/subagents.ts
# New in HAL-C2. The provider adapters apply it: see the "subagent" scenarios in providers/claude.feature,
# providers/codex.feature and the @backlog ones of the providers that have a knob not wired yet.

Feature: Subagents setting
  Agents can split work up with their provider's own built-in subagents, whose work shows in
  HAL-C2 only as a summary, or with HAL-C2 workers (`delegate_task`), which have threads the
  user can open and follow. One setting chooses between them for an environment. It is read
  when an agent's session starts: Claude restarts its session when its next turn starts, and a
  Codex thread keeps the choice it started with until its session restarts. An agent whose
  project turned HAL-C2's tools off has no workers to delegate to, so it keeps its provider's.

  @mc
  Scenario Outline: The MC reads the subagents setting
    Given the subagents setting is <stored>
    Then agents <must> use HAL-C2 workers instead of their provider's subagents

    Examples:
      | stored             | must     |
      | not set            | need not |
      | the provider's own | need not |
      | HAL-C2 workers     | must     |

  @mc
  Scenario: Agents that can delegate are told to use HAL-C2 workers when the setting says so
    Given the subagents setting is HAL-C2 workers
    Then the instructions given to agents end by telling them to delegate with "delegate_task"

  @mc
  Scenario: Agents that can delegate are told nothing more when the provider's own subagents are allowed
    Given the subagents setting is the provider's own
    Then the instructions given to agents do not tell them to delegate with "delegate_task" instead

  # tests/tst_SettingsPages.qml (test_subagentsRowOffersProviderOrHalC2Workers) proves the desktop row;
  # the phone's shares the same rows and has no test of its own yet.
  @desktop @mobile @tui @backlog-desktop @backlog-mobile
  Scenario: The user chooses whose subagents agents use
    Given an MC with a project "project-one"
    When the user opens the subagents settings
    Then the subagents setting reads "Provider's own"
    When the user chooses HAL-C2 workers
    Then the MC keeps HAL-C2 workers as the subagents setting
