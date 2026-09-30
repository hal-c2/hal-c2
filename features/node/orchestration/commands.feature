# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   apps/server-ex/lib/hal_c2/orchestration.ex (orchestration.dispatchCommand, result sequence)
#   apps/server-ex/lib/hal_c2/streams.ex (one writer per stream, transactions)
#   apps/server/src/orchestration-v2/Orchestrator.ts, CommandReceiptStore.ts,
#     EffectOutbox.ts, EffectWorker.ts, KeyedSerialExecutor.ts
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2Command, command receipts)
Feature: How the engine accepts commands
  Clients and agents change orchestration state only by dispatching commands.
  Each accepted command answers with the thread's sequence after it, so a
  client can tell when its projection has caught up.

  Background:
    Given a node with a project "demo"
    And thread "t1" exists in "demo"

  @node
  Scenario: An accepted command answers with the thread's new sequence
    Given "t1" is at sequence 10
    When a client pins "t1"
    Then the answer is a sequence after 10
    And a client subscribed to "t1" has seen that sequence once the change reaches it

  @node
  Scenario: A command that changes nothing leaves the sequence alone
    Given "t1" was last visited at 10:00 and is at sequence 12
    When a client records a visit to "t1" at 09:00
    Then the answer is sequence 12

  @node
  Scenario: Commands on one thread apply one at a time
    When two clients rename "t1" at the same moment
    Then one rename applies after the other and "t1" ends with the later title

  @node
  Scenario: A refused command changes nothing
    When a client dispatches a command that fails its checks on "t1"
    Then it fails with a message saying why
    And the sequence of "t1" is unchanged

  @node
  Scenario: A command of an unknown type is refused
    When a client dispatches a command of type "thread.teleport"
    Then it fails and nothing changes

  @node
  Scenario: Repeating a command id returns the first outcome
    Given a client dispatched message "hello" to "t1" with command id "c1"
    When it dispatches the same command again with command id "c1" after a reconnect
    Then no second message or run is created
    And the answer is the sequence of the first dispatch

  @node
  Scenario: A command id cannot be replayed on another thread
    Given a client dispatched a command to "t1" with command id "c3"
    When a client dispatches a command with id "c3" to "t2"
    Then the command is rejected
    And nothing about "t2" changes

  @node
  Scenario: A rejected command id stays rejected
    Given a command with id "c2" was rejected
    When it is dispatched again with id "c2"
    Then it is rejected again without being re-evaluated

  @node
  Scenario: Side effects of an accepted command survive a restart
    Given a command was accepted and its provider work was not yet started
    When the node restarts
    Then the pending provider work runs once after the restart
