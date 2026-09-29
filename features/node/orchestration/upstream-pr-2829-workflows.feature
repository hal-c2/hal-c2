# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   upstream commits b882b109f, 2c388dae9, d2269c385,
#     2b6f2afdc, f6924fd18, 402205e2c, b22246417, 613a1b236
#   packages/contracts/src/orchestrationV2.ts
#   apps/server-ex/lib/hal_c2/orchestration/
#   apps/server/src/mcp/
Feature: Durable thread workflows and compatible clients
  Workflow commands must work at stable provider boundaries. Read models and
  protocol clients must remain useful while the node changes underneath them.

  @node @backlog @shared
  Scenario: A provider-finished run can be forked
    Given thread "t1" has a run that the provider finished but the node has not yet displayed as settled
    When the user forks "t1" from that run
    Then the fork is created from the provider's finished turn
    And the source run is not duplicated in the fork's queue

  @node @backlog @plugin-codex
  Scenario: Codex rollback works after its app-server restarts
    Given a Codex thread has a checkpoint before the app-server restarts
    When the user rolls the thread back to that checkpoint after the restart
    Then the provider conversation is rolled back
    And the node reports the rollback as complete

  @node @backlog @plugin-pi
  Scenario: Pi rollback works past a stopped turn
    Given a Pi thread has a stopped turn followed by a checkpoint
    When the user rolls back past the stopped turn
    Then Pi resumes from the selected checkpoint
    And the stopped turn is not reused as native history

  @node @backlog @shared
  Scenario: Agent-sent messages retain their source thread
    Given a delegated child sends a message to its parent
    When the node stores the message
    Then the message records the child thread as its source
    And a client can open the source thread from the message

  @node @backlog
  Scenario: A settled thread is not rediscovered as an active pull request thread
    Given thread "t1" links a pull request that merged and "t1" has settled
    When the node refreshes pull request state
    Then "t1" is not listed as an active pull request thread

  @node @backlog
  Scenario: Thread settlement is available through the MCP read tools
    Given thread "t1" has a settlement decision
    When an agent reads "t1" through the thread list or thread read MCP tool
    Then the response includes the settlement state
    And the response includes why the thread can or cannot settle

  @node @backlog @shared
  Scenario: A client that does not know an event can keep its connection
    Given a connected client does not recognize a newly added event type
    When the node publishes that event
    Then the client skips the event
    And it continues processing later known events

  @node @backlog
  Scenario: A provider-finished run is not held open by unrelated background work
    Given a provider has finished the foreground run of thread "t1"
    And unrelated background work is still running
    When the node evaluates the run
    Then the foreground run is reported finished
    And the background work remains a separate active item

  @node @backlog
  Scenario: A missing worktree is recreated before a turn starts
    Given thread "t1" points at a worktree that no longer exists
    When the user sends a message to "t1"
    Then the node recreates the worktree from the thread branch
    And only then starts the provider turn

  @node @backlog
  Scenario: Equivalent schedule times do not duplicate a scheduled task
    Given a scheduled task has a due time with a different equivalent time format
    When the node reloads scheduled tasks
    Then it keeps one task with the same due time
    And it does not schedule a duplicate run
