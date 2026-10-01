# Sources:
#   apps/server-ex/lib/hal_c2/checkpoint.ex (hidden commit per run, private index, 10 MB diff limit)
#   apps/server-ex/lib/hal_c2/orchestration/rollback.ex (checkpoint.rollback, restoreFiles, errors)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (rolled_back runs hidden)
#   packages/contracts/src/orchestrationV2.ts (checkpoint.rollback, checkpoint.captured, checkpoint.rollback-requested)
#   apps/web/src/components/ChatView.tsx (Edit from here, Revert files too, Revert and keep changes, rollback confirm, errors)
#   apps/web/src/components/chat/V2ItemInspector.tsx (checkpoint status, Roll back)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Edit from here, Rewinding conversation)
#   apps/tui/src/timeline.ts (revertableCheckpoints)
#   apps/tui/src/components/ChatView.tsx (Revert to checkpoint, Reverted to turn N)
#   apps/desktop-qt/src/native/ThreadDiff.cpp (requestRevert, confirmRevert, cancelRevert)
#   apps/desktop-qt/qml/HalC2/Bricks/RevertDialog.qml (revert dialog, shared with a reply's Revert)
#   apps/desktop-qt/qml/HalC2/Bricks/ThreadView.qml (a reply's Revert)
#   apps/desktop-qt/tests/native/features/PanelSteps.cpp, CentreSteps.cpp

Feature: Checkpoints and rewinding
  Every finished turn leaves a checkpoint of the workspace. The user can rewind the
  conversation to before a message, with or without putting the files back.

  Background:
    Given a connected environment with the project "shop"
    And a thread in "shop" with three finished turns

  @mc
  Scenario: A finished turn leaves a checkpoint
    When the agent finishes a turn that changed "src/cart.ts"
    Then a checkpoint of the workspace is recorded for that turn
    And the user's staged changes are left as they were

  # TUI: implemented in apps/tui/src/components/ChatView.tsx. The desktop's revert is the
  # outline below, which asks first.
  @tui
  Scenario: The user reverts the thread to an earlier turn
    When the user reverts the thread to the checkpoint after turn 1
    Then turns 2 and 3 are removed from the conversation
    And the workspace files match the end of turn 1
    And the user is told "Reverted to turn 1."

  # A reply's Revert and the diff panel's ask the same question and rewind the same way.
  @desktop
  Scenario Outline: Either way in asks first, then keeps or restores the files
    When the user asks to revert to turn 1 from <where>
    And the user confirms with "<answer>"
    Then turns 2 and 3 are removed from the conversation
    And <files>
    And the user is told "Reverted to turn 1."

    Examples:
      | where          | answer           | files                                          |
      | its reply      | Keep files       | the MC is asked to leave the files as they are |
      | its reply      | Revert files too | the workspace files match the end of turn 1    |
      | the diff panel | Keep files       | the MC is asked to leave the files as they are |
      | the diff panel | Revert files too | the workspace files match the end of turn 1    |

  @mc
  Scenario: Rewinding hides the later turns from the timeline
    When the thread is rolled back to the checkpoint after turn 1
    Then turns 2 and 3 are no longer shown
    And the agent no longer remembers turns 2 and 3

  @shared @backlog
  Scenario: Editing from a message returns the prompt to the composer
    Given the composer holds the draft "also check tax"
    When the user edits from the second message and reverts the files too
    Then the conversation rewinds to before the second message
    And the second message's prompt and attachments are added to the draft

  @mc
  Scenario Outline: Rewinding can keep or restore the files
    When the thread is rewound to before turn 2 <files>
    Then the conversation ends at turn 1
    And the workspace <result>

    Examples:
      | files                   | result                                   |
      | and files restored      | matches the end of turn 1                |
      | without restoring files | keeps every change made by turns 2 and 3 |

  @shared @backlog
  Scenario: The user cancels a rewind
    When the user starts editing from the second message
    And the user cancels
    Then the conversation and the workspace are unchanged

  @shared @backlog-mobile @backlog-tui
  Scenario: Rolling back to a checkpoint asks first because it cannot be undone
    When the user rolls back to a checkpoint
    Then the user is asked to confirm that the rollback cannot be undone

  @desktop
  Scenario: Cancelling a revert leaves the thread as it was
    When the user starts reverting to the checkpoint after turn 1
    And the user cancels the revert
    Then no rollback is sent
    And turns 1 to 3 are still shown

  @desktop
  Scenario: A revert the MC refuses says why
    Given the MC refuses rollbacks with "Interrupt the current turn before rewinding."
    When the user reverts the thread to the checkpoint after turn 1
    Then the user sees an "error" toast "Could not revert to turn 1" saying "Interrupt the current turn before rewinding."
    And turns 1 to 3 are still shown

  @mc
  Scenario Outline: A rewind that cannot happen says why
    Given <situation>
    When the user rewinds to before turn 2 and restores files
    Then the rewind is refused with "<message>"

    Examples:
      | situation                               | message                                                                                                                                                      |
      | the agent is still working              | Interrupt the current turn before rewinding.                                                                                                                 |
      | another thread shares the workspace     | File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead. |
      | the thread has no provider conversation | No active provider thread exists for rollback.                                                                                                               |

  @shared @backlog
  Scenario Outline: The client explains why it cannot rewind
    Given <situation>
    When the user edits from the second message
    Then the user is told "<message>"

    Examples:
      | situation                                     | message                                                                                    |
      | the provider cannot rewind its history        | This provider does not support reverting conversation history. Start a new thread instead. |
      | the message's attachments are still preparing | Wait for attachments to finish preparing before rewinding.                                 |
      | the composer has no room for the attachments  | Make room for this message's attachments in the composer before rewinding.                 |

  @mc
  Scenario: A checkpoint that no longer exists cannot be restored
    Given the checkpoint after turn 1 has gone stale
    When the user rewinds to it
    Then the rewind is refused because the checkpoint cannot be restored
