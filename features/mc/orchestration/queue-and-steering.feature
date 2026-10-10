# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (message.dispatch dispatchMode and deliveryIntent,
#     queued-run.cancel, queued-run.edit, queued-run.reorder, queued-message.promote-to-steer,
#     queue.resume, run.updated, message.updated, turn-item.updated)
#   apps/server-ex/lib/hal_c2/orchestration.ex (decide_message, queue_run, steer, restart_promoted)
#   apps/server/src/orchestration-v2/ (dispatch mode resolution)
#   apps/server/src/orchestration-v2/Orchestrator.ts (dispatchSteerIntoRun; a steer for a
#     completed run starts immediately)
#   apps/server/src/orchestration-v2/CommandPolicy.ts, QueuedRunOrder.ts (steer and restart
#     targets, delegated task results ahead of queued messages)
#   apps/server/src/orchestration-v2/EffectWorker.ts (provider-turn.steer failure handling)
#   apps/server/src/orchestration-v2/ProviderTurnControlService.ts (a restart waits for the interrupted turn)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts, ClaudeAdapterV2.ts (steerTurn
#     with attachments)
#   apps/server/src/orchestration-v2/testkit/ProviderSwitch.integration.test.ts (queued capability)
#   docs/user/ (composer queue and steer guidance)
Feature: Queueing, steering and restarting
  While a turn is active, a new message either steers it, waits in the thread's
  queue, or interrupts it and goes first. The engine decides from the message's
  delivery intent, its dispatch mode, and whether the provider can be steered.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo"

  @mc
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

  @mc
  Scenario: An automatic message queues behind a turn whose provider cannot be steered
    Given "t1" has a running turn on "grok"
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue at position 1

  @mc
  Scenario: An automatic message queues while the turn is still starting
    Given "t1" has a turn that is starting on "codex"
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue

  @backlog @mc
  Scenario Outline: Queueing needs the provider the message is queued for to support a queue
    Given "t1" has a running turn on a provider that <active>
    When the user queues "Next" for a provider that <selected>
    Then the message <result>
    And "t1" stays on the model of the running turn

    Examples:
      | active                  | selected                | result                                              |
      | cannot queue messages   | can queue messages      | waits in the queue                                  |
      | can queue messages      | cannot queue messages   | is refused saying queued messages are not supported |

  @mc
  Scenario: A message sent to queue after the active turn always queues
    Given "t1" has a running turn on "codex"
    When the user sends "Later" to "t1" to queue after the active turn
    Then "Later" waits at the end of the queue

  @mc
  Scenario: An explicit steer that the provider cannot take interrupts and goes first
    Given "t1" has a running turn on "grok" and a queued message "Old"
    When the user sends "Now" to "t1" as a steer
    Then "Now" is first in the queue and "Old" moves to position 2
    And the running turn is interrupted
    And a run for "Now" starts when the interrupted run ends

  @mc
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

  @backlog @mc
  Scenario: A restart whose interrupted turn never ends fails instead of running two turns
    Given "t1" has a running turn
    When the user sends "Instead" to "t1" to restart the active turn and the provider never ends the interrupted turn
    Then the restart fails saying the provider turn did not end before the restart
    And no second turn is started alongside the first

  @mc
  Scenario: A steer the provider refuses while its turn runs is reported to the sender
    Given "t1" has a running turn on "codex"
    And the provider refuses the steer
    When the user tries to send "Also" to "t1" as a steer
    Then the send fails saying Codex did not take the message into its running turn
    And "Also" is neither queued nor added to the running turn

  @mc
  Scenario Outline: A steer carries the message's files and images to the provider
    Given "t1" has a running turn on "<provider>"
    When the user steers "t1" with "Look at this" and an attached screenshot
    Then the running turn answers "Look at this" having seen the screenshot

    Examples:
      | provider    |
      | codex       |
      | claudeAgent |

  @mc
  Scenario: Queued messages keep their own run ids and ordinals when they start
    Given "t1" has a running turn and a queued message "Next" with ordinal 3
    When the running turn completes
    Then the run for "Next" starts with ordinal 3
    And its user message turn item is marked as a queued turn

  @mc
  Scenario: Cancelling a queued message
    Given "t1" has a running turn and queued messages "A", "B" and "C"
    When the user cancels queued message "B"
    Then "B" is cancelled
    And "A" and "C" are at positions 1 and 2

  @mc
  Scenario: Cancelling a run that is not queued changes nothing
    Given "t1" has a running turn
    When the user cancels the running turn as if it were queued
    Then the running turn is unchanged

  @mc
  Scenario: Editing a queued message changes its text
    Given "t1" has a queued message "Tpyo"
    When the user edits the queued message to "Typo"
    Then the queued message reads "Typo"

  @mc
  Scenario: Editing a message that already started changes nothing
    Given "t1" has a run for "Started" that is running
    When the user edits that message as if it were queued
    Then the message still reads "Started"

  @mc
  Scenario: Editing a queued message can replace its attachments and context
    Given "t1" has a queued message with an attached screenshot
    When the user edits the queued message removing the screenshot and adding a file reference
    Then the queued message carries only the file reference

  @mc
  Scenario: Reordering a queued message before another
    Given "t1" has queued messages "A", "B" and "C"
    When the user moves "C" before "A"
    Then the queue order is "C", "A", "B"

  @mc
  Scenario: Reordering without a known target moves the message to the end
    Given "t1" has queued messages "A", "B" and "C"
    When the user moves "A" before a message that is not queued
    Then the queue order is "B", "C", "A"

  @mc
  Scenario: Promoting a queued message steers the running turn when possible
    Given "t1" has a running turn on "codex" and a queued message "Hurry"
    When the user promotes "Hurry" to a steer
    Then the queued run for "Hurry" is cancelled and leaves the queue
    And "Hurry" joins the running turn as a promoted steer

  @mc
  Scenario: Promoting a queued message on a provider that cannot steer interrupts and goes first
    Given "t1" has a running turn on "grok" and queued messages "A" and "Hurry"
    When the user promotes "Hurry" to a steer
    Then "Hurry" is first in the queue
    And the running turn is interrupted

  @mc
  Scenario: Queued messages wait after an MC restart until the user resumes the queue
    Given "t1" had a queued message when the MC restarted
    Then the queued message is held
    And no run starts for it

  @mc
  Scenario: Resuming the queue starts the next queued message
    Given "t1" has held queued messages "A" and "B"
    When the user resumes the queue of "t1"
    Then no queued message is held
    And a run for "A" starts

  @mc @shared @backlog-mobile
  Scenario: A usage limit keeps the queue as it was
    Given "t1" has a running turn and queued messages "one" and "two"
    When the provider stops "t1" because its usage limit was reached
    Then "one" and "two" stay queued in their original order
    And neither is discarded or sent early

  @mc
  Scenario: A held queue does not start when a run ends
    Given "t1" has a held queued message "A"
    When another run of "t1" ends
    Then "A" is still queued

  @mc @backlog
  Scenario: A queued delegated task result runs before the user's queued messages
    Given "t1" has a running turn and a queued message "Next"
    And a delegated task of "t1" finished, so its result is queued after "Next"
    When the running turn completes
    Then the turn carrying the task result starts first
    And "Next" starts after it

  @mc @backlog
  Scenario Outline: A queued delegated task result cannot be handled like a queued message
    Given "t1" has a running turn and a queued delegated task result
    When the user tries to <action> the queued result
    Then the command fails with "<message>"

    Examples:
      | action                  | message                                                      |
      | promote it to a steer   | Automatic completion deliveries cannot be promoted to Steer. |
      | move it in the queue    | Automatic completion deliveries cannot be reordered.         |
      | edit                    | Automatic completion deliveries cannot be edited.            |

  @mc @backlog
  Scenario: A queued message cannot be moved ahead of a queued delegated task result
    Given "t1" has a queued delegated task result and a queued message "Next"
    When the user moves "Next" before the queued result
    Then the command fails with "Queued messages cannot be reordered ahead of automatic completion delivery."

  @mc @backlog
  Scenario: Cancelling a queued delegated task result gives up waking the agent for it
    Given "t1" has a running turn and a queued result for delegated tasks "one" and "two"
    When the user cancels the queued result
    Then it leaves the queue
    And the agent of "t1" is not woken again for "one" or "two"
    And their results can still be read from each task's status

  @mc @backlog
  Scenario: A message queued while the queue is held is held too
    Given "t1" has a held queued message "A"
    When the user queues "B" on "t1"
    Then "B" is held behind "A"
    And no run starts until the user resumes the queue

  @mc @backlog
  Scenario: A queued message that could not start says so in the timeline
    Given "t1" has a running turn and a queued message "Next"
    When the running turn completes and the provider for "Next" cannot be started
    Then the run for "Next" fails
    And the timeline shows an error titled "Queued provider could not start" with the reason

  @mc @backlog
  Scenario: A steer that arrives after its turn finished starts a new turn
    Given "t1" had a running turn that completed
    When a steer the user sent for that turn reaches the MC afterwards
    Then the message is not lost
    And it starts a new turn of "t1"

  @mc @backlog
  Scenario Outline: A steer or restart must name the thread's active turn
    Given "t1" has a running turn and an older turn that <state>
    When the user sends "Now" to "t1" as a <delivery> of the older turn
    Then the command is refused
    And the running turn is not disturbed

    Examples:
      | state           | delivery |
      | completed       | restart  |
      | was interrupted | steer    |
      | was interrupted | restart  |

  @mc @backlog
  Scenario Outline: Compacting and signing out cannot be steered into a turn
    Given "t1" has a running turn on "codex"
    When the user sends "<command>" by itself to "t1" as a steer
    Then the command fails with "<message>"

    Examples:
      | command  | message                                                                                          |
      | /compact | Context compaction must run as a separate turn. Queue it or wait for the active turn to finish. |
      | /logout  | Signing out must run as a separate turn. Queue it or wait for the active turn to finish.        |

  @mc @backlog
  Scenario Outline: A turn that is compacting or signing out cannot be steered
    Given "t1" has a running turn started by "<command>" sent by itself
    When the user sends "Also check the docs" to "t1" as a steer
    Then the command fails with "<message>"

    Examples:
      | command  | message                                                            |
      | /compact | Wait for context compaction to finish before steering the thread. |
      | /logout  | Wait for sign-out to finish before steering the thread.           |

  @mc @backlog
  Scenario: A queued message cannot be edited down to nothing
    Given "t1" has a queued message "Next" with no attachments
    When the user edits the queued message to empty text
    Then the command fails saying the queued run cannot be edited to an empty message
    And the queued message still reads "Next"

  @mc @backlog
  Scenario Outline: The queue of an archived thread cannot be worked
    Given "t1" has a queued message "Next" and is archived
    When a client tries to <action>
    Then the command fails with "Thread t1 is not active."

    Examples:
      | action                           |
      | promote "Next" to a steer        |
      | resume the queue of "t1"         |
