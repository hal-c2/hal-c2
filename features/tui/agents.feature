# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/AgentsPanel.qml (the Agents tab: state, model, elapsed, activity)
#   apps/desktop-qt/src/native/AgentsModel.cpp (ordering, status words, elapsed)
#   apps/tui/src/host/agentsState.ts, apps/tui/src/host/agentsPanel.ts
#   apps/tui/qml/HalC2/Tui/AgentsPanel.qml
#   Shared domain: timeline/plans-and-subagents.feature owns the Agents tab on the desktop.

Feature: The terminal client's agents panel
  A thread's workers sit in a panel beside the conversation: what each is doing, on which
  provider and model, for how long, and its latest word. A worker waiting on the user comes
  first, so a blocked worker is never lost below the ones still working. The user follows a
  worker into its own thread and stops one that has gone astray.

  Background:
    Given the terminal is 80 by 24
    And the open thread has delegated three workers, one waiting on an approval

  @tui
  Scenario: The agents panel lists the workers, the one that needs the user first
    When the user opens the agents panel
    Then the agents panel lists, in order:
      | Review the docs | Needs approval |
      | Fix the tests   | Working        |
      | Write notes     | Completed      |
    And each worker shows its provider, model and how long it has run
    And the agents panel's summary counts "!1 ●1 ✓1"

  @tui
  Scenario: Opening a worker follows its own thread
    Given the agents panel is open
    When the user selects the worker "Fix the tests" and presses "Enter"
    Then the conversation shows the worker's thread
    And the agents panel offers the way back to "Delegating"

  @tui
  Scenario: On a narrow terminal, opening a worker shows its thread in place of the panel
    Given the terminal is narrowed to 72 columns
    And the agents panel is open
    When the user selects the worker "Fix the tests" and presses "Enter"
    Then the conversation shows the worker's thread
    And the agents panel is closed and the prompt has the keys

  @tui
  Scenario: Stopping a worker asks first, then asks its run to stop
    Given the agents panel is open
    When the user selects the worker "Fix the tests" and presses "c"
    Then the client asks "Stop Fix the tests?" with "Keep it running" chosen
    When the user chooses "Stop the worker"
    Then the client stops the run of the worker's thread

  @tui
  Scenario: A worker that ended cannot be stopped
    Given the agents panel is open
    When the user selects the worker "Write notes" and presses "c"
    Then the status says "Write notes already ended."
    And nothing was stopped

  @tui
  Scenario: Escape gives the keys back and the leader key hides the panel
    Given the agents panel is open
    When the user presses "Esc"
    Then the prompt has the keys and the agents panel stays open
    When the user presses "Ctrl+X" and then "a"
    Then the agents panel has the keys
    When the user presses "Ctrl+X" and then "a"
    Then the agents panel is closed
