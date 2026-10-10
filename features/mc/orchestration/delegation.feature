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
#   apps/server/src/orchestration-v2/Orchestrator.ts (wake policy, completion cohorts, at most two
#     wakes per turn), Notification.ts, NotificationMailbox.ts, SubagentProjection.ts (notification
#     summaries, result fallbacks, work states, subagent thread titles)
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

  # A report that times out on a busy thread is tried again; it settles the task as
  # the child's run ended, and when, not as things stood when the report was sent.
  @mc
  Scenario: A task whose end report timed out settles on the retry
    Given the agent in "parent" delegated a task without waiting
    When the subagent completes while its caller is too busy to hear it
    Then the task, its node and its turn item are "completed"
    And the task ended when its child's turn did
    And "parent" receives one wake turn

  @mc
  Scenario: A task rolled back before its end report is retried settles as cancelled
    Given the agent in "parent" delegated a task without waiting
    When the subagent completes, and the user rolls back its turn before the caller hears it
    Then the task, its node and its turn item are "cancelled"
    And "parent" is told the task was cancelled without an answer

  # Its next turn reports when it ends.
  @mc
  Scenario: A task rolled back and at work again when its end report is retried keeps running
    Given the agent in "parent" delegated a task without waiting
    When the subagent completes, and the user rolls back its turn and asks again before the caller hears it
    Then the task, its node and its turn item are "running"

  # Its turn is interrupted at boot and continued; it reports when the continued turn ends.
  @mc
  Scenario: A task still working when the MC stopped ends with the turn that continues it
    Given project "demo" continues threads after a server update
    And the agent in "parent" delegates a task
    When the MC restarts
    Then the task, its node and its turn item end "completed"
    And the task ended when its child's turn did

  # Its turn is interrupted at boot and not continued, so nothing will ever report it.
  @mc
  Scenario: A task whose subagent is not continued after a restart is interrupted
    Given the project does not continue threads after an update
    And the agent in "parent" delegates a task
    When the MC restarts
    Then the task, its node and its turn item are "interrupted"

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

  @backlog @mc
  Scenario Outline: A task's role frames the subagent's prompt
    When the agent in "parent" delegates the task "Check the schema" with <role>
    Then the subagent's first message is <prompt>

    Examples:
      | role        | prompt                                                              |
      | role "qa"   | "Act as the qa sub-agent for this task." and then the task          |
      | role "general" | the task unchanged                                               |
      | no role     | the task unchanged                                                  |

  @backlog @mc
  Scenario Outline: A task can name a provider by its kind instead of a configured instance
    Given "parent" runs on a "codex" instance that is <parent_instance>
    And another healthy "codex" instance exists
    When the agent in "parent" delegates a task naming the provider kind "codex"
    Then the subagent runs on <instance>

    Examples:
      | parent_instance | instance                        |
      | healthy         | the instance "parent" runs on   |
      | disabled        | the other healthy instance      |

  @backlog @mc
  Scenario Outline: A task naming a provider that cannot run is refused with the reason
    When the agent in "parent" delegates a task and <naming>
    Then the tool fails with code "<code>"
    And the message says "<message>"

    Examples:
      | naming                                                     | code                 | message                                         |
      | names the provider kind "codex" but none is healthy        | provider_unavailable | No available V2 provider instance for driver codex. |
      | names an instance that is not registered                   | provider_unavailable | Provider instance ghost is not registered.      |
      | names an instance of a different kind than the kind given  | invalid_request      | Provider instance claude uses driver claudeAgent, not codex. |
      | names a model the provider does not advertise              | model_unavailable    | Model nope is not advertised by provider codex. |

  @backlog @mc
  Scenario Outline: A task's model options are checked against the model
    When the agent in "parent" delegates a task with <options>
    Then the tool fails with code "invalid_request"
    And the message names the model and the provider and says <problem>

    Examples:
      | options                                           | problem                                       |
      | the same option given twice                       | the option was specified more than once       |
      | an option the model does not have                 | the option is unknown and lists the supported options |
      | a true or false option given a word               | a boolean is expected                         |
      | a choice option given a value outside its choices | the value must be one of the choices          |

  @backlog @mc
  Scenario: Repeating a delegation with the same request key starts one subagent
    Given the agent in "parent" delegated a task with request key "k1"
    When it repeats the request with request key "k1"
    Then no second subagent thread is started
    And it receives the same task id

  @backlog @mc
  Scenario: Reading a finished subagent's answer acknowledges its delivery
    Given a delegated task of "parent" finished with an answer that fits one read
    When the agent in "parent" reads the subagent's thread from the start
    Then the task's delivery is "acknowledged" and "parent" is not woken for it

  @backlog @mc
  Scenario: Waiting on a subagent's thread does not acknowledge its delivery
    Given a delegated task of "parent" finished
    When the agent in "parent" waits on the subagent's thread
    Then the wait reports only the status
    And the task's delivery is still pending

  @backlog @mc
  Scenario: Cancelling a task whose subagent has nothing running to interrupt is refused
    Given the agent in "parent" delegated a task that is not finished and whose subagent has no running turn
    When the agent cancels the task
    Then the tool fails with code "task_not_cancellable"

  @backlog @mc
  Scenario Outline: The message that wakes the caller names the finished tasks and how to read them
    Given the turn of "parent" ended while <tasks> were still working
    When <tasks> finish
    Then the agent of "parent" is woken with "<text>"

    Examples:
      | tasks                         | text                                                                                                                |
      | task "task-1"                 | Delegated task task-1 reached a terminal state. Use task_status with taskId task-1 to read the result.             |
      | tasks "task-1" and "task-2"   | Delegated tasks task-1, task-2 reached terminal states. Use task_status with each taskId to read the results.      |

  @backlog @mc
  Scenario Outline: A delivered task result shows in the caller's timeline as a notification
    Given the turn of "parent" ended while <tasks> were still working
    When <ending> and "parent" is woken for it
    Then the timeline of "parent" shows a delegated task notification reading "<summary>"
    And the notification's outcome is "<outcome>"

    Examples:
      | tasks                       | ending                                | summary                    | outcome   |
      | a task titled "Audit deps"  | the task completes                    | Audit deps finished        | completed |
      | a task titled "Audit deps"  | the task fails                        | Audit deps failed          | failed    |
      | a task titled "Audit deps"  | the task is cancelled or interrupted  | Audit deps stopped         | cancelled |
      | a task with no title        | the task completes                    | Delegated task finished    | completed |
      | three tasks                 | all three complete                    | 3 delegated tasks finished | completed |
      | three tasks                 | two complete and one is cancelled     | 3 delegated tasks stopped  | cancelled |
      | three tasks                 | one fails and one is cancelled        | 3 delegated tasks failed   | failed    |

  @backlog @mc
  Scenario: A task set to wake only an idle caller does not interrupt a caller that is still working
    Given the agent in "parent" delegated a task that wakes it only once it is idle
    When the subagent completes while the turn of "parent" is still running
    Then "parent" is not woken and nothing is queued for it
    And the result can be read from the task's status

  @backlog @mc
  Scenario Outline: A task set to always wake the caller reaches a caller that is still working
    Given "parent" runs on a provider that <steering>
    And the agent in "parent" delegated a task that always wakes it
    When the subagent completes while the turn of "parent" is still running
    Then the wake message <delivery>
    And the running turn is never interrupted or restarted for it

    Examples:
      | steering                       | delivery                                  |
      | can take messages mid-turn     | joins the running turn                    |
      | cannot take messages mid-turn  | waits in the queue behind the running turn |

  @backlog @mc
  Scenario: A task that finishes while a wake is still queued joins that wake
    Given a wake for the finished task "one" of "parent" is queued behind a running turn
    When task "two" of the same turn finishes
    Then no second wake is queued
    And the queued wake now names "one" and "two"

  @backlog @mc
  Scenario: A task that finishes while the wake turn runs is delivered in one follow-up wake
    Given "parent" is running the turn that woke it for task "one"
    When tasks "two" and "three" of the same original turn finish
    Then they are not added to the running wake
    And when that turn ends "parent" is woken once more, for "two" and "three" together

  @backlog @mc
  Scenario: A caller's turn is woken at most twice for the tasks it started
    Given the tasks of one turn of "parent" already woke it twice
    When another task of that turn finishes
    Then "parent" is not woken a third time
    And the task's result stays readable from its status

  @backlog @mc
  Scenario Outline: A task result is not delivered into a caller that is gone
    Given the agent in "parent" delegated a task without waiting
    And "parent" was <gone> while the task was still working
    When the subagent completes
    Then "parent" is not woken and no message is added to it
    And the task's delivery is "disposed"
    And the result can still be read from the task's status

    Examples:
      | gone     |
      | archived |
      | deleted  |

  @backlog @mc
  Scenario: Stopping the caller's turn stops its tasks from waking it later
    Given the agent in "parent" delegated tasks "one" and "two" without waiting
    When the user interrupts the turn of "parent"
    And "one" and "two" finish afterwards
    Then "parent" is not woken for either
    And a wake already queued for that turn is cancelled

  @backlog @mc
  Scenario Outline: Acknowledging tasks of a queued wake trims or cancels the wake
    Given a wake for the finished tasks "one" and "two" of "parent" is queued
    When the agent <reads>
    Then the queued wake <outcome>

    Examples:
      | reads                                   | outcome                     |
      | acknowledges the result of "one"        | names only "two"            |
      | acknowledges the results of both tasks  | is cancelled and never runs |
      | disposes the delivery of both tasks     | is cancelled and never runs |

  @backlog @mc
  Scenario Outline: Delivery commands only apply to tasks the MC started for that thread
    Given a subagent that the provider of "parent" started by itself
    When a client tries to <action> for that subagent
    Then the command fails saying it is not an app-owned task of thread "parent"

    Examples:
      | action                              |
      | acknowledge its completion delivery |
      | dispose its completion delivery     |
      | change its wake policy              |

  @backlog @mc
  Scenario: Setting the wake policy a task already has is refused
    Given the agent in "parent" delegated task "task-1" that always wakes it
    When the wake policy of "task-1" is set to always again
    Then the command fails with "Delegated task task-1 already wakes the parent with completionWake always."

  @backlog @mc
  Scenario Outline: Switching a finished task to always wake the caller
    Given a task of "parent" that wakes it only once idle finished while its turn was running
    And the turn of "parent" <state>
    When the task's wake policy is changed to always
    Then <outcome>

    Examples:
      | state            | outcome                                                              |
      | is still running | the result is delivered to "parent" now                              |
      | has ended        | no wake is sent and the result stays readable from the task's status |

  @backlog @mc
  Scenario Outline: A delegated task needs a turn of the caller that is still active
    When a client requests a delegated task for <target> of "parent"
    Then the command fails saying <reason>

    Examples:
      | target                                             | reason                                         |
      | a run that already ended                           | the parent run is not active                   |
      | the active run and a node that is not part of it   | the parent node is not part of the active run  |

  @backlog @mc
  Scenario Outline: What a task's result says when the subagent left no answer
    When the subagent's turn <ending>
    Then the task's result reads "<result>"

    Examples:
      | ending                                                    | result                                             |
      | completes without an assistant message                    | Child task completed without an assistant result.  |
      | is interrupted without an assistant message               | Child task ended with status interrupted.          |
      | fails with "Rate limit reached" after it already answered | Rate limit reached                                 |

  @backlog @mc
  Scenario: A task whose subagent is waiting on tasks of its own is not finished yet
    Given the agent in "parent" delegated a task
    And the subagent's turn ended while tasks it delegated itself are still working
    When the agent in "parent" asks for the task's status
    Then the work state is "waiting_for_children"
    And it becomes "result_available" once those tasks are done

  @backlog @mc
  Scenario: A subagent the provider started without a title or prompt is named after its parent
    Given thread "parent" is titled "Fix the parser"
    When the provider of "parent" starts its second subagent with neither a title nor a prompt
    Then the subagent's thread is titled "Fix the parser subagent 2"

  @backlog @mc
  Scenario Outline: A task whose subagent still owes work is not finished yet
    Given the agent in "parent" delegated a task
    And the subagent's turn ended while <owed>
    When the agent in "parent" asks for the task's status
    Then the work state is "waiting_for_children"

    Examples:
      | owed                                                              |
      | a command it started is still running in the background           |
      | a task it delegated finished but that result has not reached it   |

  @backlog @mc
  Scenario: A turn that only handled a monitor update is not the task's result
    Given the agent in "parent" delegated a task and the subagent answered "Done: 3 files"
    And the subagent later ran a turn only to handle an update from a monitor
    When the agent in "parent" asks for the task's result
    Then the result is "Done: 3 files"

  @backlog @mc
  Scenario: A rolled-back turn of the subagent is not the task's result
    Given the agent in "parent" delegated a task and the subagent answered "First" and then "Second"
    And the subagent's second turn was rolled back
    When the agent in "parent" asks for the task's result
    Then the result is "First"

  @backlog @mc
  Scenario: A subagent the provider started is titled from its prompt, cut to 72 characters
    When the provider of "parent" starts a subagent with no title and a prompt of 100 characters
    Then the subagent's thread is titled with the prompt's first 69 characters followed by "..."

  @backlog @mc
  Scenario: A subagent starts awake whatever state its parent is in
    Given thread "parent" is snoozed
    When the provider of "parent" starts a subagent
    Then the subagent's thread is not snoozed, settled or archived
    And it has never been visited

  @backlog @mc
  Scenario: A provider-started subagent's prompt is shown as sent by its parent thread
    When the provider of "parent" starts a subagent with the prompt "Check the tests"
    Then the subagent's thread opens with the message "Check the tests" written by the agent
    And the message names "parent" as the thread that sent it
