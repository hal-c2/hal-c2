# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (subagent.updated, delegated_task.request,
#     delegated_task.wake-policy, delegated_task.completion-delivery.acknowledge,
#     delegated_task.completion-delivery.dispose, notification.delivery.accept, node.updated,
#     turn-item.updated)
#   packages/contracts/src/orchestratorMcp.ts (delegate_task, task_status, task_cancel, error codes)
#   apps/server-ex/lib/hal_c2/orchestration/delegation.ex
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (abandon: a crashed caller's run)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex (a lost completion settles at boot)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (delegate_task, task_status, task_cancel)
#   apps/server/src/orchestration-v2/ (delegated task reactor and completion delivery)
#   apps/server/src/mcp/ (orchestrator toolkit)
Feature: Delegating tasks to subagents
  A running agent can hand a task to a subagent. The engine starts a child thread
  marked as a subagent of the caller, records the task in the caller's timeline,
  and brings the child's answer back when it finishes.

  Background:
    Given an MC with a project "demo"
    And thread "parent" has a running turn on "codex" in worktree "/work/p"

  @mc
  Scenario: Delegating a task starts a subagent thread
    When the agent in "parent" delegates "Write the migration\nUse the new schema"
    Then a new thread marked as a subagent of "parent" exists
    And it was created by an agent through MCP
    And its first message is the task prompt
    And its title is "Write the migration"

  @mc
  Scenario: Task titles are cut to 80 characters
    When the agent in "parent" delegates a task whose first line is 120 characters long
    Then the subagent thread's title is the first 80 characters

  @mc
  Scenario: The subagent works where the caller works
    When the agent in "parent" delegates a task
    Then the subagent thread works in worktree "/work/p"

  @mc
  Scenario: The subagent uses the caller's model unless the task names another
    When the agent in "parent" delegates a task without naming a provider
    Then the subagent runs on "codex" with the caller's model

  @mc
  Scenario: A task can name another provider, which uses its default model
    When the agent in "parent" delegates a task to "claudeAgent" without a model
    Then the subagent runs on "claudeAgent" with that provider's default model

  @mc
  Scenario: The caller's timeline records the task
    When the agent in "parent" delegates a task
    Then "parent" has a subagent task owned by the app with a node and a turn item
    And the task id starts with "node:subagent:"

  @mc
  Scenario Outline: Delegation is refused when it cannot be honoured
    Given <situation>
    When the agent in "parent" delegates a task
    Then the tool fails with code "<code>"

    Examples:
      | situation                                                         | code                               |
      | "parent" has no active run on the calling provider                | parent_not_active                  |
      | the task names a provider this MC does not have                   | provider_unavailable               |
      | the task asks for full access while "parent" is approval-required | runtime_mode_escalation_denied     |
      | the task asks for default mode while "parent" is in plan mode     | interaction_mode_escalation_denied |

  @mc
  Scenario: Waiting for a task returns its result when it finishes
    When the agent in "parent" delegates a task and waits
    And the subagent completes with "Migration written"
    Then the wait returns status completed with summary "Migration written"

  @mc
  Scenario: A wait that times out leaves the task running
    When the agent in "parent" delegates a task and waits 1 second
    And the subagent is still working after 1 second
    Then the wait returns the task as working and says the wait timed out

  @mc
  Scenario Outline: Wait timeouts are clamped
    When the agent in "parent" delegates a task and waits <asked> ms
    Then the wait lasts at most <used> ms

    Examples:
      | asked      | used      |
      | 0          | 1         |
      | 99,000,000 | 3,600,000 |
      | none       | 600,000   |

  @mc
  Scenario: A background task delivers its result to the caller as a message
    Given the agent in "parent" delegated a task without waiting
    When the subagent completes with "Done"
    Then "parent" receives a system message carrying the delegated task result "Done"
    And the message runs after the caller's active turn
    And the task delivery is "delivered"

  @mc
  Scenario: Each later completion wakes the caller again
    Given the agent in "parent" delegated tasks "one", "two" and "three" without waiting
    And "parent" was woken for the completion of "one"
    When "two" and "three" complete afterwards
    Then "parent" is woken again for them
    And completions that arrive together may share one wake turn

  @mc
  Scenario: A completion delivered twice wakes the caller once
    Given the agent in "parent" delegated a task without waiting
    When the subagent completes
    And the same completion is delivered again after a reconnect
    Then "parent" receives one wake turn
    And the repeat is acknowledged without another wake

  @mc
  Scenario: A waited-for task that finishes while the caller is busy is only acknowledged
    Given the agent in "parent" delegated a task and is waiting
    When the subagent completes
    Then the task delivery is "acknowledged"
    And no result message is queued into "parent"

  @mc
  Scenario: A waited-for task that finishes after the caller went idle is delivered
    Given the agent in "parent" delegated a task and waited until it timed out
    And the turn of "parent" ended
    When the subagent completes
    Then "parent" receives the delegated task result as a message

  # The task runs in its own thread, so it outlives the caller's runtime.
  @mc
  Scenario: A task keeps working when its caller's runtime crashes
    Given the agent in "parent" delegated a task that is still working
    When the runtime running the turn of "parent" crashes
    Then the turn of "parent" fails
    And the task, its node and its turn item are "running"
    When the subagent completes
    Then the task, its node and its turn item are "completed"

  # The report of a child's end can be lost: the caller's thread too busy to take it,
  # or the MC stopping first. The child's own runs still say how the task ended.
  @mc
  Scenario: A task whose end never reached its caller settles when the MC starts
    Given the agent in "parent" delegated a task that completed
    And the caller was never told the task ended
    When the MC restarts
    Then the task, its node and its turn item are "completed"
    And the task summary is "Done"
    And the task ended when its child's turn did
    And the task delivery is "disposed"

  @mc
  Scenario: A task whose answer was rolled back settles as cancelled when the MC starts
    Given the agent in "parent" delegated a task that completed
    And the caller was never told the task ended
    And the user rolled back the task's turn in its thread
    When the MC restarts
    Then the task, its node and its turn item are "cancelled"

  # Its turn is interrupted at boot, and may be continued; it reports when it ends.
  @mc
  Scenario: A task still working when the MC stopped is not settled when it starts
    Given the agent in "parent" delegates a task
    When the MC restarts
    Then the task, its node and its turn item are "running"

  @mc
  Scenario: The task result is the subagent's last answer
    When the subagent's turn ends with two assistant messages
    Then the task summary is the last one

  @mc
  Scenario: A task that ends without an answer says so
    When the subagent fails without an assistant message
    Then the delivered result says there was no answer

  @mc
  Scenario: Checking a task's status
    Given the agent in "parent" delegated a task
    When the agent asks for the task's status
    Then it sees the child thread, provider, model, status and whether child runs are pending
    And the work state is "working" until the task ends and "result_available" after

  @mc
  Scenario: Checking a task that does not exist
    When the agent in "parent" asks for the status of task "node:subagent:none"
    Then the tool fails with code "task_not_found"

  @mc
  Scenario: Cancelling a running task interrupts the subagent
    Given the agent in "parent" delegated a task that is still working
    When the agent cancels the task
    Then the subagent's turn is interrupted
    And the task is cancelled and its delivery disposed

  @mc
  Scenario: Cancelling a finished task is refused
    Given the agent in "parent" delegated a task that completed
    When the agent cancels the task
    Then the tool fails with code "task_not_cancellable"

  @mc
  Scenario: A client or agent changes a task's wake policy after starting it
    Given the agent in "parent" delegated a task and is waiting
    When the wake policy is changed to always
    Then the result is delivered as a message when the task ends

  @mc
  Scenario: The caller acknowledges or disposes a task's completion delivery
    Given a delegated task of "parent" finished with a delivered result
    When the caller acknowledges the delivery naming the run that saw it
    Then the task records which run observed its result
    And disposing a delivery stops it from being delivered again

  @mc
  Scenario: The provider confirms it accepted a mailbox delivery
    Given a delegated task result was delivered into "parent" as a message
    When the provider accepts the delivery
    Then the message is recorded as accepted, separately from the agent reading it

  @mc
  Scenario: Delegated tasks can be requested with a command outside MCP
    When a client requests a delegated task for the active run of "parent"
    Then a subagent thread starts as if the agent had delegated it
