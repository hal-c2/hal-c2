# Sources:
#   packages/contracts/src/orchestrationV2.ts (message.dispatch dispatchMode and deliveryIntent,
#     queued-run.cancel, queued-run.edit, queued-run.reorder, queued-message.promote-to-steer,
#     queue.resume, run.updated, message.updated, turn-item.updated)
#   apps/server-ex/lib/hal_c2/orchestration.ex (decide_message, queue_run, steer, restart_promoted)
#   apps/server/src/orchestration-v2/ (dispatch mode resolution)
#   docs/user/ (composer queue and steer guidance)
Feature: Queueing, steering and restarting
  While a turn is active, a new message either steers it, waits in the thread's
  queue, or interrupts it and goes first. The engine decides from the message's
  delivery intent, its dispatch mode, and whether the provider can be steered.

  Background:
    Given a node with a project "demo"
    And thread "t1" exists in "demo"

  @node
  Scenario Outline: An automatic message steers a running turn when its provider can take it
    Given "t1" has a <status> turn on "<provider>"
    When the user sends "Also check the docs" to "t1" with automatic delivery
    Then the message joins the active run as a steer
    And the run has a user message turn item marked as a steer

    Examples:
      | status  | provider    |
      | running | codex       |
      | waiting | codex       |
      | running | claudeAgent |

  @node
  Scenario: An automatic message queues behind a turn whose provider cannot be steered
    Given "t1" has a running turn on "opencode"
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue at position 1

  @node
  Scenario: An automatic message queues while the turn is still starting
    Given "t1" has a turn that is starting on "codex"
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue

  @node
  Scenario: A message sent to queue after the active turn always queues
    Given "t1" has a running turn on "codex"
    When the user sends "Later" to "t1" to queue after the active turn
    Then "Later" waits at the end of the queue

  @node
  Scenario: An explicit steer that the provider cannot take interrupts and goes first
    Given "t1" has a running turn on "opencode" and a queued message "Old"
    When the user sends "Now" to "t1" as a steer
    Then "Now" is first in the queue and "Old" moves to position 2
    And the running turn is interrupted
    And a run for "Now" starts when the interrupted run ends

  @node
  Scenario Outline: A restart interrupts the active turn and goes first
    Given "t1" has a running turn and a queued message "Old"
    When the user sends "Instead" to "t1" <how>
    Then "Instead" is first in the queue
    And the running turn is interrupted
    And a run for "Instead" starts when the interrupted run ends

    Examples:
      | how                          |
      | with restart delivery        |
      | to restart the active turn   |

  @node
  Scenario: A steer the provider refuses falls back to the queue
    Given "t1" has a running turn on "codex"
    And the provider refuses the steer because the turn just ended
    When the user sends "Also" to "t1" as a steer
    Then "Also" is sent as a queued message instead

  @node
  Scenario: Queued messages keep their own run ids and ordinals when they start
    Given "t1" has a running turn and a queued message "Next" with ordinal 3
    When the running turn completes
    Then the run for "Next" starts with ordinal 3
    And its user message turn item is marked as a queued turn

  @node
  Scenario: Cancelling a queued message
    Given "t1" has a running turn and queued messages "A", "B" and "C"
    When the user cancels queued message "B"
    Then "B" is cancelled
    And "A" and "C" are at positions 1 and 2

  @node
  Scenario: Cancelling a run that is not queued changes nothing
    Given "t1" has a running turn
    When the user cancels the running turn as if it were queued
    Then the running turn is unchanged

  @node
  Scenario: Editing a queued message changes its text
    Given "t1" has a queued message "Tpyo"
    When the user edits the queued message to "Typo"
    Then the queued message reads "Typo"

  @node
  Scenario: Editing a message that already started changes nothing
    Given "t1" has a run for "Started" that is running
    When the user edits that message as if it were queued
    Then the message still reads "Started"

  @node
  Scenario: Editing a queued message can replace its attachments and context
    Given "t1" has a queued message with an attached screenshot
    When the user edits the queued message removing the screenshot and adding a file reference
    Then the queued message carries only the file reference

  @node
  Scenario: Reordering a queued message before another
    Given "t1" has queued messages "A", "B" and "C"
    When the user moves "C" before "A"
    Then the queue order is "C", "A", "B"

  @node
  Scenario: Reordering without a known target moves the message to the end
    Given "t1" has queued messages "A", "B" and "C"
    When the user moves "A" before a message that is not queued
    Then the queue order is "B", "C", "A"

  @node
  Scenario: Promoting a queued message steers the running turn when possible
    Given "t1" has a running turn on "codex" and a queued message "Hurry"
    When the user promotes "Hurry" to a steer
    Then the queued run for "Hurry" is cancelled and leaves the queue
    And "Hurry" joins the running turn as a promoted steer

  @node
  Scenario: Promoting a queued message on a provider that cannot steer interrupts and goes first
    Given "t1" has a running turn on "opencode" and queued messages "A" and "Hurry"
    When the user promotes "Hurry" to a steer
    Then "Hurry" is first in the queue
    And the running turn is interrupted

  @node
  Scenario: Queued messages wait after a node restart until the user resumes the queue
    Given "t1" had a queued message when the node restarted
    Then the queued message is held
    And no run starts for it

  @node
  Scenario: Resuming the queue starts the next queued message
    Given "t1" has held queued messages "A" and "B"
    When the user resumes the queue of "t1"
    Then no queued message is held
    And a run for "A" starts

  @node
  Scenario: A held queue does not start when a run ends
    Given "t1" has a held queued message "A"
    When another run of "t1" ends
    Then "A" is still queued
