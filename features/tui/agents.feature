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
  Scenario: On a narrow terminal, going back to the parent shows it in place of the panel
    Given the terminal is narrowed to 72 columns
    And the agents panel is open
    And the user selects the worker "Fix the tests" and presses "Enter"
    And the conversation shows the worker's thread
    When the user opens the agents panel
    And the user presses "u"
    Then the conversation shows "Delegating"
    And the agents panel is closed and the prompt has the keys

  @tui
  Scenario: A click selects a worker, and a second click opens it
    Given the agents panel is open
    And the agents panel selects the worker "Review the docs"
    When the user clicks the worker "Fix the tests"
    Then the conversation shows "Delegating"
    And the agents panel selects the worker "Fix the tests"
    When the user clicks the worker "Fix the tests"
    Then the conversation shows the thread of "Fix the tests"

  @tui
  Scenario: A click on a worker the keys left and came back to only selects it
    Given the agents panel is open
    And the user clicked the worker "Fix the tests"
    And the user moves the selection to the worker "Write notes"
    And the user moves the selection to the worker "Fix the tests"
    When the user clicks the worker "Fix the tests"
    Then the conversation shows "Delegating"
    And the agents panel selects the worker "Fix the tests"
    When the user clicks the worker "Fix the tests"
    Then the conversation shows the thread of "Fix the tests"

  @tui
  Scenario: Opening a worker the thread filter hides clears the filter
    Given the thread list is filtered to "Delegating"
    And the agents panel is open
    When the user selects the worker "Fix the tests" and presses "Enter"
    Then the conversation shows the worker's thread
    And the thread list is no longer filtered and the worker's thread stays selected

  @tui
  Scenario: Stopping a worker asks first, then asks its run to stop
    Given the agents panel is open
    When the user selects the worker "Fix the tests" and presses "c"
    Then the client asks "Stop Fix the tests?" with "Keep it running" chosen
    And nothing was stopped
    When the user chooses "Stop the worker" in the question
    Then the client requests an interrupt of the run the user was asked about

  @tui
  Scenario: A worker with no run to interrupt is not stopped
    Given the agents panel is open
    And the worker "Fix the tests" has no run to interrupt
    When the user selects the worker "Fix the tests" and presses "c"
    Then the status says "Fix the tests has no run to interrupt."
    And nothing was stopped

  @tui
  Scenario: A run that started while the user was asked is not stopped
    Given the agents panel is open
    When the user selects the worker "Fix the tests" and presses "c"
    And the worker "Fix the tests" starts another run
    And the user chooses "Stop the worker" in the question
    Then the status says "Fix the tests started another run; press c again to stop it."
    And nothing was stopped

  @tui
  Scenario: A stop question whose run arrives after the user left the panel is not asked
    Given the agents panel is open
    And reading the run of "Fix the tests" waits
    When the user selects the worker "Fix the tests" and presses "c"
    And the user presses "Esc"
    And the run of "Fix the tests" is read
    Then no question is asked
    And the prompt has the keys and the agents panel stays open
    And nothing was stopped

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

  @tui
  Scenario: Clicking the prompt takes the keys, and the leader key gives them back to the panel
    Given the agents panel is open
    When the user clicks the prompt
    Then the prompt has the keys and the agents panel stays open
    When the user presses "Ctrl+X" and then "a"
    Then the agents panel has the keys

  @tui
  Scenario: Hiding the agents panel from the command palette closes it
    Given the agents panel is open
    When the user presses "Esc"
    And the user chose "Hide agents panel" from the command palette
    Then the agents panel is closed

  @tui
  Scenario: The agents panel the file browser hides is offered to show, not to hide
    Given the agents panel is open
    And the user presses "Esc"
    And the user browses the open thread's files
    When the user chose "Show agents panel" from the command palette
    Then the agents panel has the keys
    And the file browser is closed

  @tui
  Scenario: Showing the agents panel from the file browser closes the browser
    Given the user browses the open thread's files
    When the user chose "Show agents panel" from the command palette
    Then the agents panel has the keys
    And the file browser is closed
