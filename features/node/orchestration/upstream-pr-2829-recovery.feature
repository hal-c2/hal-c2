# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   upstream commits 4018a6c9c, fc1ecf874, 39e6fbb6d, b39e62dc9, 94f92a7a3,
#     eec0514c3, 00e1a9c99, fe6553ebf, 977bf4a48
#   apps/server/src/orchestration-v2/ (runtime recovery and serialized orchestration)
#   apps/server-ex/lib/hal_c2/orchestration/ (node recovery and provider sessions)
Feature: Recovering provider work without losing orchestration state
  The node owns queued work, provider sessions and delegated work. A provider
  restart or a detached session must not leave a thread, queue or parent wake
  in a state that the user cannot recover.

  Background:
    Given a node with a project "demo"

  @node @backlog
  Scenario: Queued work remains available after a usage limit
    Given thread "t1" is working and has queued messages "one" and "two"
    When the provider stops "t1" because its usage limit was reached
    Then both queued messages remain in their original order
    And the messages are not silently discarded or sent early

  @node @backlog
  Scenario: Restart recovery identifies background work that was killed
    Given thread "t1" has a settled run with a provider background command
    When the node restarts and the provider process is gone
    Then the background command is marked interrupted
    And the provider is told that the node killed its background work

  @node @backlog
  Scenario: A settled thread continues when restart recovery finds lost background work
    Given thread "t1" is settled and its background work disappeared during a restart
    And the project allows continuation after a restart
    When the node completes startup recovery
    Then "t1" receives one continuation turn
    And the continuation names the lost background work

  @node @backlog
  Scenario: A parent is woken once for a delegated completion
    Given parent thread "parent" is waiting for child thread "child"
    When "child" finishes a delegated task
    And the same completion is delivered again after a reconnect
    Then "parent" receives one wake turn
    And the completion is acknowledged without another wake

  @node @backlog
  Scenario: A detached provider session can still receive a handoff
    Given thread "t1" has detached its provider session after a completed run
    When the user changes "t1" to another provider and sends "continue"
    Then the handoff starts from the durable thread history
    And the detached session is not required

  @node @backlog @plugin-cursor
  Scenario: An abandoned Cursor send is recovered
    Given a Cursor send for thread "t1" has a local run record but no live provider session
    When the node reconciles provider sessions
    Then the abandoned send is completed or failed explicitly
    And a later message can start a new Cursor run

  @node @backlog @plugin-opencode
  Scenario: A crashed OpenCode server is released
    Given an OpenCode child server belongs to thread "t1"
    When the node detects that its owning provider process crashed
    Then the child server is stopped
    And no OpenCode process remains owned by "t1"

  @node @backlog
  Scenario: A failed rollback is visible to the user
    Given thread "t1" is being rolled back to a checkpoint
    When restoring the checkpoint fails
    Then the rollback finishes with an error
    And "t1" is not left waiting forever
    And the failed rollback marker does not replace the last valid checkpoint

  @node @backlog
  Scenario: Editing from a stopped run uses the stopped run as its source
    Given thread "t1" has a stopped run with an assistant message
    When the user edits from that message
    Then the new turn starts from that message's checkpoint boundary
    And the stopped run remains visible as history

  @node @backlog
  Scenario: Provider context occupancy survives a model handoff
    Given thread "t1" has used 80 percent of its current provider context
    When the user hands "t1" to another model on the same provider
    Then the next run reports the handoff's context occupancy
    And it does not reset the meter to zero until the provider reports new usage

  @node @backlog
  Scenario: A provider session closes only after an abortable turn is stopped
    Given Claude has an active turn in thread "t1"
    When the node releases the Claude session
    Then Claude receives an abort request before the session closes
    And the turn is not reported as successful
