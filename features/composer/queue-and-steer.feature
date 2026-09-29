# Sources:
#   docs/user/composer.md (follow-up behaviour, queued messages, editing a queued message)
#   apps/server-ex/lib/hal_c2/orchestration.ex (queued runs, steer, restart dispatch, queue hold)
#   apps/web/src/components/chat/QueuedRunsControl.tsx
#   apps/web/src/components/chat/ComposerPrimaryActions.tsx (queue, steer, stop)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (stop while running, steer or queue, mod+Enter)
#   apps/desktop-qt/tests/tst_Composer.qml
#   apps/desktop-qt/src/native/ComposerController.cpp (the queue in the turn, cancel, steer and edit)
#   apps/tui/src/components/ChatView.tsx (Esc interrupts)
#   apps/tui/qml/HalC2/Tui/ShellKeymap.qml (a held Esc does not repeat)
#   packages/shared/src/keybindings.ts (composer.sendAlternate, thread.steerQueuedMessage, thread.editQueuedMessage)
#   packages/contracts/src/orchestrationV2.ts (queued-run.cancel, queued-run.edit, queued-run.reorder, queued-message.promote-to-steer, queue.resume, run.interrupt)
#   packages/contracts/src/settings.ts (followUpBehavior)

Feature: Follow-ups while the agent is working
  A message sent while a turn is running either waits in the queue or steers
  the running turn. Queued messages can be reordered, edited, promoted and
  removed, and the user can always stop the running turn.

  Background:
    Given a thread whose agent is working on a turn

  @node
  Scenario: A message sent to the queue during a turn waits for the thread to be idle
    When the user queues "also update the docs"
    Then "also update the docs" is queued behind the running turn
    And it starts once the thread is idle

  @node
  Scenario Outline: Steering joins the running turn only where the provider can take it
    Given the thread runs on <provider>
    When the user steers the running turn with "use the new API"
    Then <outcome>

    Examples:
      | provider | outcome                                                                  |
      | Codex    | the running turn receives "use the new API"                              |
      | Claude   | the running turn receives "use the new API"                              |
      | OpenCode | the running turn receives "use the new API"                              |
      | Grok     | the running turn is interrupted and "use the new API" runs next          |

  @node
  Scenario: A steer the provider rejects is refused, not quietly queued
    Given the provider rejects the steer
    When the user tries to steer the running turn with "stop and summarize"
    Then the user is told the provider did not take the message
    And "stop and summarize" is neither queued nor part of the running turn
    And the running turn keeps working

  @node
  Scenario: Restarting with a message interrupts the turn and runs the message next
    Given "later" is queued
    When the user restarts the turn with "start over with tests first"
    Then the running turn is interrupted
    And "start over with tests first" runs before "later"

  @desktop
  Scenario Outline: The follow-up setting decides what sending during a turn does
    Given the follow-up behaviour setting is "<setting>"
    When the user <action> "<message>"
    Then "<message>" <outcome>

    Examples:
      | setting | action                    | message | outcome                     |
      | queue   | sends                     | tweak   | is queued                   |
      | queue   | sends the opposite way    | tweak   | steers the running turn     |
      | steer   | sends                     | tweak   | steers the running turn     |
      | steer   | sends the opposite way    | tweak   | is queued                   |

  @backlog @mobile
  Scenario: The phone sends a follow-up the other way than its setting
    Given the follow-up behaviour setting is "queue"
    When the user sends "tweak" the opposite way from the phone
    Then "tweak" steers the running turn

  @node
  Scenario: Reordering the queue changes what runs next
    Given "a", "b" and "c" are queued in that order
    When the user moves "c" before "a"
    Then the queue order is "c", "a", "b"

  @node
  Scenario: Editing a queued message replaces its text before it runs
    Given "fix typo" is queued
    When the user edits it to "fix all typos"
    Then the queued message reads "fix all typos"
    And it keeps its place in the queue

  @desktop
  Scenario: Editing the last queued message from the composer and cancelling restores the prior draft
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    Then the composer holds "fix typo"
    When the user cancels the edit
    Then the composer holds "unrelated draft" again
    And the queued message still reads "fix typo"

  @node
  Scenario Outline: Promoting a queued message steers the running turn
    Given the thread runs on <provider>
    And "check the logs" is queued
    When the user promotes it to a steer
    Then <outcome>
    And "check the logs" is no longer waiting in the queue

    Examples:
      | provider | outcome                                                          |
      | Codex    | the running turn receives "check the logs"                       |
      | Claude   | the running turn receives "check the logs"                       |
      | OpenCode | the running turn receives "check the logs"                       |
      | Grok     | the running turn is interrupted and "check the logs" runs next   |

  @node
  Scenario: Removing a queued message cancels it
    Given "never mind" is queued
    When the user removes it from the queue
    Then "never mind" never runs

  @node
  Scenario: The queue is held after a node restart until the user resumes it
    Given "later" was queued when the node restarted
    When the node comes back
    Then the queue is held and "later" does not start on its own
    When the user resumes the queue
    Then "later" starts

  @desktop
  Scenario: Stopping the running turn from an empty composer
    Given the composer is empty
    When the user chooses to stop
    Then the running turn is interrupted

  @desktop
  Scenario: A shortcut bound to stop interrupts the running turn
    Given "thread.stop" is bound to mod+shift+.
    When the user presses mod+shift+.
    Then the running turn is interrupted

  @tui
  Scenario: Escape clears the draft first, then stops the turn
    Given the user has typed "wait"
    When the user presses Escape
    Then the draft is empty
    And the turn is still running
    When the user presses Escape again
    Then the running turn is interrupted

  @tui
  Scenario: Holding Escape to close a picker leaves the turn running
    When the user clicks "All projects"
    And the user holds Escape
    Then the turn is still running

  @desktop
  Scenario: Queued messages are listed in the order they run
    Given "check the logs" and "update the docs" are queued
    Then the composer lists the queued messages "check the logs" and "update the docs"

  @desktop
  Scenario: Removing a queued message cancels its run
    Given "check the logs" and "update the docs" are queued
    When the user removes "check the logs" from the queue
    Then the node is asked to cancel the queued run of "check the logs"

  @desktop
  Scenario: A removal the node refuses is reported
    Given "check the logs" and "update the docs" are queued
    And the node refuses "queued-run.cancel" with "run already started"
    When the user removes "check the logs" from the queue
    Then the user sees an "error" toast "Failed to remove the queued message." saying "run already started"

  @desktop
  Scenario: A queued message can steer the running turn
    Given "check the logs" and "update the docs" are queued
    When the user steers the running turn with the queued "update the docs"
    Then the node is asked to steer the running turn with the queued run of "update the docs"

  @desktop
  Scenario: A steer the node refuses is reported
    Given "check the logs" and "update the docs" are queued
    And the node refuses "queued-message.promote-to-steer" with "provider cannot steer"
    When the user steers the running turn with the queued "update the docs"
    Then the user sees an "error" toast "Failed to steer with the queued message." saying "provider cannot steer"

  @desktop
  Scenario: Saving an edited queued message changes it and gives the draft back
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    And the user sends "fix all typos" from the composer
    Then the node is asked to change the queued run of "fix typo" to "fix all typos"
    And the composer holds "unrelated draft" again

  @desktop
  Scenario: An edit the node refuses stays in the composer
    Given "fix typo" is queued
    And the node refuses "queued-run.edit" with "run already started"
    When the user starts editing the last queued message from the start of the composer
    And the user sends "fix all typos" from the composer
    Then the user sees an "error" toast "Could not save the edited queued message." saying "run already started"
    And the composer holds "fix all typos"

  @desktop
  Scenario: An edit whose message starts running is kept when the draft was empty
    Given "fix typo" is queued
    When the user starts editing the last queued message from the start of the composer
    And the user changes the edit to "fix all typos"
    And the queued run of "fix typo" starts
    Then the user sees an "info" toast "Queued message is no longer queued" saying "Your unsaved edit was kept in the composer."
    And the composer holds "fix all typos"

  @desktop
  Scenario: An edit whose message starts running is dropped when the draft had text
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    And the user changes the edit to "fix all typos"
    And the queued run of "fix typo" starts
    Then the user sees a "warning" toast "Queued message is no longer queued" saying "Your unsaved edit was discarded."
    And the composer holds "unrelated draft" again

  @desktop
  Scenario: Leaving the thread ends the edit
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    And the user switches to thread B and back to thread A
    Then the composer holds "unrelated draft" again
    And the queued message still reads "fix typo"
