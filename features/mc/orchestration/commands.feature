# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   apps/server-ex/lib/hal_c2/orchestration.ex (orchestration.dispatchCommand, result sequence)
#   apps/server-ex/lib/hal_c2/streams.ex (one writer per stream, transactions)
#   apps/server/src/orchestration-v2/Orchestrator.ts, CommandReceiptStore.ts,
#     EffectOutbox.ts, EffectWorker.ts, KeyedSerialExecutor.ts, EventSink.ts
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2Command, command receipts)
#   apps/server/src/orchestration-v2/UserFacingErrors.ts, CommandPolicy.ts (refusals in the
#     provider's name, the most specific reason of a wrapped failure)
Feature: How the engine accepts commands
  Clients and agents change orchestration state only by dispatching commands.
  Each accepted command answers with the thread's sequence after it, so a
  client can tell when its projection has caught up.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo"

  @mc
  Scenario: An accepted command answers with the thread's new sequence
    Given "t1" is at sequence 10
    When a client pins "t1"
    Then the answer is a sequence after 10
    And a client subscribed to "t1" has seen that sequence once the change reaches it

  @mc
  Scenario: A command that changes nothing leaves the sequence alone
    Given "t1" was last visited at 10:00 and is at sequence 12
    When a client records a visit to "t1" at 09:00
    Then the answer is sequence 12

  @mc
  Scenario: Commands on one thread apply one at a time
    When two clients rename "t1" at the same moment
    Then one rename applies after the other and "t1" ends with the later title

  @mc
  Scenario: A refused command changes nothing
    When a client dispatches a command that fails its checks on "t1"
    Then it fails with a message saying why
    And the sequence of "t1" is unchanged

  @mc
  Scenario: A command of an unknown type is refused
    When a client dispatches a command of type "thread.teleport"
    Then it fails and nothing changes

  @mc
  Scenario: Repeating a command id returns the first outcome
    Given a client dispatched message "hello" to "t1" with command id "c1"
    When it dispatches the same command again with command id "c1" after a reconnect
    Then no second message or run is created
    And the answer is the sequence of the first dispatch

  @mc
  Scenario: A command id cannot be replayed on another thread
    Given a client dispatched a command to "t1" with command id "c3"
    When a client dispatches a command with id "c3" to "t2"
    Then the command is rejected
    And nothing about "t2" changes

  @mc
  Scenario: A rejected command id stays rejected
    Given a command with id "c2" was rejected
    When it is dispatched again with id "c2"
    Then it is rejected again without being re-evaluated

  @mc
  Scenario: Side effects of an accepted command survive a restart
    Given a command was accepted and its provider work was not yet started
    When the MC restarts
    Then the pending provider work runs once after the restart

  @mc @backlog
  Scenario: A command that fails while it is recorded leaves nothing behind
    When recording a command on "t1" fails part way through
    Then "t1" has none of its events, no receipt for it and none of its side effects
    And the same command can be dispatched again

  @mc @backlog
  Scenario: A side effect that fails is retried with growing delays and then given up
    Given a command was accepted and its side effect keeps failing
    Then the side effect is tried 5 times in all
    And the waits between tries double from 100 milliseconds, never more than 30 seconds
    And after the last try it is recorded as failed with its error

  @mc @backlog
  Scenario Outline: After the server process is lost, unfinished work tied to the old provider process is cancelled
    Given <work> was pending or under way when the server process ended
    When the MC starts again
    Then that work is not run again
    And it is recorded as "Cancelled because the server process ended before the effect completed."

    Examples:
      | work                           |
      | starting a provider turn       |
      | interrupting a provider turn   |
      | steering a provider turn       |
      | restarting a provider turn     |
      | answering a provider's request |

  @mc @backlog
  Scenario Outline: After the server process is lost, work that is safe to repeat is run again
    Given <work> was under way when the server process ended
    When the MC starts again
    Then that work is run again from the start

    Examples:
      | work                                 |
      | continuing a thread after an update  |
      | detaching a provider session         |
      | rolling back a provider conversation |
      | capturing a checkpoint               |
      | cleaning up a thread's terminals     |
      | removing a thread's attached files   |
      | generating a thread title            |

  @mc @backlog
  Scenario: Side effects of one thread run in order while other threads proceed
    Given "t1" has two side effects waiting and thread "t2" has one
    When the first side effect of "t1" is slow
    Then the second side effect of "t1" waits for it
    And the side effect of "t2" runs without waiting

  @mc @backlog
  Scenario: Generating a title neither waits for nor delays a thread's provider work
    Given "t1" is generating its title
    When the user sends a message to "t1"
    Then the provider turn starts without waiting for the title
    And a slow provider turn does not hold back the title

  @mc @backlog
  Scenario: Work cancelled before it starts never reaches the provider
    Given a message to "t1" was accepted and its provider turn has not started
    When the user interrupts "t1"
    Then the provider turn is never started

  @mc @backlog
  Scenario: Work cancelled while it runs is stopped and not retried
    Given a side effect of "t1" is running
    When a later command cancels it
    Then it stops and is not tried again
    And the next side effect of "t1" runs

  @mc @backlog
  Scenario: Interrupting a turn the provider says has already stopped counts as done
    Given the user interrupted "t1" just as its provider turn ended
    When the provider answers that the turn is not active
    Then the interrupt is treated as done
    And it is not retried

  @mc @backlog
  Scenario Outline: A command refused for something the provider cannot do names the provider and what it cannot do
    Given "t1" runs on "Codex", which cannot <ability>
    When a client dispatches a command that needs it
    Then the client is told "<message>"

    Examples:
      | ability                                        | message                                                                                         |
      | queue messages behind an active run            | Codex cannot queue messages behind an active run.                                               |
      | take a message into an active run              | Codex cannot redirect an active run. Stop it first, then send the message.                      |
      | be interrupted and restarted with a message    | Codex cannot redirect an active run. Stop it first, then send the message.                      |
      | be interrupted                                 | Codex cannot stop a run once it has started.                                                    |
      | fork a conversation natively                   | Codex cannot fork this thread natively.                                                         |
      | fork from an earlier turn                      | Codex cannot fork from an earlier point in this thread.                                         |
      | rewind its conversation                        | Codex cannot rewind its conversation, so this checkpoint cannot be restored on this thread.     |
      | report its conversation after a rewind         | Codex did not report its rewound conversation state, so the checkpoint was not restored.        |
      | receive a context handoff                      | Codex cannot receive the context handoff needed for this switch.                                |
      | say reliably when its runs finish              | Codex cannot confirm when its runs finish reliably enough for this.                             |

  @mc @backlog
  Scenario: A delivery the provider cannot make at all is refused in the provider's name
    Given "t1" runs on "Codex" and has a turn running
    When a client sends a message in a way the provider supports no form of
    Then the client is told "Codex cannot deliver a message that way right now."

  @mc @backlog
  Scenario: A provider the MC has no display name for is named after its instance
    Given "t1" runs on a provider instance called "acmeAgent" that cannot queue messages
    When a client queues a message behind the running turn of "t1"
    Then the client is told "Acme cannot queue messages behind an active run."

  @mc @backlog
  Scenario: A refused command is reported with its most specific reason
    Given a command on "t1" fails inside the provider with "The sandbox denied the write."
    When the failure reaches the client wrapped in the engine's general dispatch errors
    Then the client is told "The sandbox denied the write."
    And the general "Failed to dispatch orchestration command" wrapper is not shown

  # Legacy: Orchestrator.control-reads.test.ts, RunCompletionReads.test.ts. Visits fire on
  # every activity bump of an open thread, so their cost must not grow with the thread.
  @mc @backlog
  Scenario Outline: A small command on a long thread is decided without reading its history
    Given "t1" has a very long history
    When a client <command>
    Then the command is accepted without the messages and turn items of "t1" being read

    Examples:
      | command                                   |
      | renames "t1"                              |
      | records a visit to "t1"                   |
      | pins "t1"                                 |
      | resumes the queue of "t1"                 |
      | answers a pending request of "t1"         |
