# Sources:
#   https://github.com/pingdotgg/t3code/pull/22117
#   https://github.com/pingdotgg/t3code/pull/20037
#   https://github.com/pingdotgg/t3code/pull/16595
#   https://github.com/pingdotgg/t3code/pull/20025
#   https://github.com/pingdotgg/t3code/pull/19801
#   https://github.com/pingdotgg/t3code/pull/19759
#   https://github.com/pingdotgg/t3code/pull/15331
#   https://github.com/pingdotgg/t3code/pull/21487
#   https://github.com/pingdotgg/t3code/pull/20310
#   https://github.com/pingdotgg/t3code/pull/19058
#   https://github.com/pingdotgg/t3code/pull/19019
#   https://github.com/pingdotgg/t3code/pull/20213
#   https://github.com/pingdotgg/t3code/pull/19538
#   https://github.com/pingdotgg/t3code/pull/19521
#   https://github.com/pingdotgg/t3code/pull/18459
#   https://github.com/pingdotgg/t3code/pull/14416
#   https://github.com/pingdotgg/t3code/pull/17028
#   https://github.com/pingdotgg/t3code/pull/19102 (covered: a task's own worktree, cut from the caller's local commits)
#   https://github.com/pingdotgg/t3code/pull/17696
#   https://github.com/pingdotgg/t3code/pull/18065
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/23886
#   https://github.com/pingdotgg/t3code/pull/24782
#   https://github.com/pingdotgg/t3code/pull/24887
#   https://github.com/pingdotgg/t3code/pull/23542
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
#     wakes per turn, dropped in hal-c2/hal-c2#892), Notification.ts, NotificationMailbox.ts,
#     SubagentProjection.ts (notification summaries, result fallbacks, work states, subagent
#     thread titles)
#   apps/server/src/mcp/ (orchestrator toolkit)
#   https://github.com/pingdotgg/t3code/pull/15115
#   https://github.com/pingdotgg/t3code/pull/25359
#   https://github.com/pingdotgg/t3code/pull/25672
#   https://github.com/pingdotgg/t3code/pull/22581
#   https://github.com/pingdotgg/t3code/pull/22653
#   https://github.com/pingdotgg/t3code/pull/22709
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
    And its first message ends with the task prompt
    And its title is "Write the migration"

  @mc
  Scenario: The subagent is told whom it works for and that its last message is the report
    When the agent in "parent" delegates a task
    Then the subagent's first message names "parent" as the thread that delegated it
    And it says the final message is the report to that thread
    And it says to finish its own work, including its own workers, before the last turn

  @mc
  Scenario: Task titles are cut to 80 characters
    When the agent in "parent" delegates a task whose first line is 120 characters long
    Then the subagent thread's title is the first 80 characters

  @mc
  Scenario: The subagent works where the caller works
    When the agent in "parent" delegates a task
    Then the subagent thread works in worktree "/work/p"

  @mc
  Scenario: A task that asks to inherit works where the caller works
    When the agent in "parent" delegates a task with workspace "{'type':'inherit'}"
    Then the subagent thread works in worktree "/work/p"

  @mc
  Scenario: A task can ask for its own new worktree, cut from the caller's local commits
    Given "parent" has a commit that is not on any other branch
    When the agent in "parent" delegates a task with workspace "{'type':'worktree'}"
    Then the subagent thread works in a new worktree other than "/work/p"
    And that worktree has the caller's commit
    And the task's status reports that worktreePath and branch
    And the subagent's first turn starts in it, after it was prepared

  @mc
  Scenario: A task's new worktree can name its branch and base
    When the agent in "parent" delegates a task with workspace "{'type':'worktree','baseRef':'main','branch':'task/a'}"
    Then the subagent thread works in a new worktree on branch "task/a"
    # startFromOrigin defaults to false; true fetches and starts from origin's copy of baseRef

  @mc
  Scenario: A caller that needs approval can ask for the root checkout it already works in
    Given the task's caller "parent" works in the project root
    And the task's caller "parent" is approval-required
    When the agent in "parent" delegates a task with workspace "{'type':'root'}"
    Then the subagent thread works in the project root

  @mc
  Scenario: A task can use another worktree of the project
    Given the project has another worktree "/work/other" on branch "other"
    When the agent in "parent" delegates a task with workspace "{'type':'existing_worktree','worktreePath':'/work/other'}"
    Then the subagent thread works in worktree "/work/other" on branch "other"

  @mc
  Scenario Outline: A workspace that cannot be honoured refuses the task before it starts
    Given the task asks for the workspace "<workspace>"
    When the agent in "parent" delegates a task
    Then the tool fails with code "workspace_invalid"
    And "parent" has no subagent task
    And the project has no worktree besides "/work/p"

    Examples:
      | workspace                                                |
      | {'type':'existing_worktree','worktreePath':'/nowhere'}   |
      | {'type':'existing_worktree','worktreePath':'relative'}   |
      | {'type':'worktree','branch':'main'}                      |
      | {'type':'worktree','baseRef':'no-such-ref'}              |

  @mc
  Scenario: A caller that needs approval cannot ask for another workspace
    Given the task asks for the workspace "{'type':'worktree'}"
    And the task's caller "parent" is approval-required
    When the agent in "parent" delegates a task
    Then the tool fails with code "workspace_escalation_denied"
    And "parent" has no subagent task

  # Upstream #20213: worktree delegation from a checkout outside the project is refused
  @mc
  Scenario: A new worktree is refused for a caller working outside the project's repository
    Given a caller thread whose checkout is not part of its project's repository
    When it delegates a task in a new worktree
    Then the delegation is refused with advice to share the caller's workspace
    And no task is created

  @mc
  Scenario: A worktree that cannot be prepared ends the task, not the caller's checkout
    Given adding the next worktree fails
    When the agent in "parent" delegates a task with workspace "{'type':'worktree'}"
    Then the task ends "failed" with the result "Workspace preparation failed"
    And the subagent never ran
    And retrying the subagent's setup is refused

  @mc
  Scenario: Cancelling a worktree's preparation ends the task
    Given the next worktree is held while it is prepared
    And the agent in "parent" delegated a task with workspace "{'type':'worktree'}"
    When the worktree setup is cancelled
    Then the task ends "cancelled" with the result "Workspace preparation was cancelled"
    And the subagent never ran

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
  Scenario: A task asking for an access mode its provider lacks is refused with the modes it has
    Given "parent" is in full access
    When the agent in "parent" delegates a task to Muse Code asking for auto-accept edits
    Then the tool fails and lists the access modes Muse Code offers

  @mc
  Scenario: A task that inherits an access mode its provider lacks gets the broadest one it has
    Given "parent" is in auto-accept edits
    When the agent in "parent" delegates a task to Muse Code without naming an access mode
    Then the subagent runs in the broadest mode Muse Code offers that does not exceed "parent"'s

  @mc
  Scenario: The orchestrator's capabilities list each provider's access modes
    When an agent asks for the orchestrator's capabilities
    Then each provider lists the access modes it offers

  # Upstream #14416: agents asked for a read-only reviewer picked a supervised mode, and the
  # child sat on its first approval with nobody to answer it.
  @mc
  Scenario: The delegation tool says a supervised access mode pauses the subagent
    When an agent reads the description of delegate_task
    Then it says to leave the access mode inherited unless the user asks for a supervised subagent
    And that a supervised subagent waits for a person on each action that needs approval
    And that a narrower mode is not a read-only switch, so a limit belongs in the task itself

  # A Claude subagent shares its thread's MCP credential; Claude names the tool call
  # behind each MCP call, which tells the subagent's calls from Claude's own.
  @mc
  Scenario: A Claude subagent cannot delegate a task
    Given thread "lead" on "claudeAgent" has a subagent running
    When the subagent in "lead" delegates a task
    Then the tool fails with code "capability_denied"
    And the refusal says a native subagent can't own HAL-C2 workers and to start such work with delegate_task
    And "lead" has no delegated task

  @mc
  Scenario: Claude still delegates while its subagent runs
    Given thread "lead" on "claudeAgent" has a subagent running
    When Claude in "lead" delegates a task itself
    Then "lead" has a delegated task

  @mc
  Scenario: A delegation without a task prompt is refused, not started empty
    When the agent in "parent" delegates with its prompt under another name
    Then the tool fails with code "invalid_task"
    And "parent" has no subagent task

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

  # Upstream #24782: a running task's result tells the agent its completion wakes it, so it ends its turn.
  # Upstream #24887: the hint says not to wait on the task or poll it.
  @mc @priority-high
  Scenario Outline: A task result that is still running tells the agent to end its turn
    Given the agent in "parent" delegated a task that is <state>
    When the agent in "parent" <checks> the task
    Then the result <hint> that the completion wakes "parent", so it should end its turn and not poll

    Examples:
      | state                                    | checks                     | hint         |
      | still running                            | asks for the status of     | says         |
      | still running                            | waits 1 second on          | says         |
      | still running                            | waits on "parent"'s run of | says         |
      | finished                                 | asks for the status of     | does not say |
      | blocked on a question for the user       | asks for the status of     | does not say |
      | blocked on an approval                   | asks for the status of     | does not say |

  @mc
  Scenario: A wait returns as soon as the subagent asks a question it is blocked on
    When the agent in "parent" delegates a task and waits
    And the subagent asks the user a question and stops until it is answered
    Then the wait returns the task as working with a pending question, not timed out
    And the result tells the agent how to read and answer the question on the subagent's thread
    And the task's later result still wakes "parent"
    But a question the subagent asks while it keeps working does not end the wait

  # Upstream #20037: a child waiting for approval left both agents blocked inside the wait.
  @mc @priority-high
  Scenario: A wait returns when the subagent is blocked on an approval
    When the agent in "parent" delegates a task and waits
    And the subagent's run stops on an approval
    Then the wait returns the task as working with the approval's request, kind and run
    And the subagent keeps running once the approval is answered
    And the task's later result still wakes "parent"

  @mc @plugin-codex
  Scenario: A Codex wait is not cut short by Codex's own tool time limit
    Given thread "parent" runs on Codex
    When the agent in "parent" delegates a task and waits 30 minutes
    And the subagent is still working after 10 minutes
    Then the wait is still open

  @backlog @mc
  Scenario: A subagent's question wakes the agent that delegated it
    Given the agent in "parent" delegated a task and its turn has ended
    When the subagent asks the user a question
    Then "parent" is woken once with the task, the subagent's thread and the question
    And it is told whether the subagent is blocked or still working
    And a wake still queued when the question is answered is cancelled

  @backlog @mc
  Scenario Outline: A subagent's question does not wake its delegating agent when <why>
    Given the agent in "parent" delegated a task
    And <situation>
    When the subagent asks the user a question
    Then "parent" is not woken for it

    Examples:
      | why                               | situation                                       |
      | the agent is waiting on the task  | the agent in "parent" is still waiting on it    |
      | the parent is archived            | "parent" is archived                            |
      | the user stopped the task         | the user stopped the task                       |

  @mc
  Scenario: A wait gives up before the caller's MCP client would
    Given thread "acp" exists in "demo"
    And "acp" has a running turn on "grok"
    And the MCP client of an ACP provider gives up on a tool call after 1 second
    When the agent in "acp" on "grok" delegates a task to "codex" and waits 2 hours
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

  # Upstream #23542: a subagent that returned an interim result and later woke itself for its
  # background command delivered that later result to nobody.
  @mc @priority-high
  Scenario: A subagent's own later wake delivers its result to the caller too
    Given the agent in "parent" delegated a task without waiting
    And the subagent answered "WAITING" and left a command running in the background
    When the command ends and the subagent's provider wakes it to finish with "Canary 42"
    Then "parent" receives a system message carrying the delegated task result "Canary 42"

  # The later two land while the caller is busy, so they ride one wake whatever the
  # timing (#634).
  @mc
  Scenario: Later completions that land while the caller works share one wake
    Given the agent in "parent" delegated tasks "one", "two" and "three" without waiting
    And "parent" was woken for the completion of "one"
    When "two" and "three" complete afterwards, while "parent" works on another turn
    Then "parent" is woken again for them
    And completions that arrive together share one wake turn

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

  # The report of a child's end can be lost: a thread it reads failing every retry,
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

  # A report that fails, as on a thread restarting under it, is tried again; it settles
  # the task as the child's run ended, and when, not as things stood when the report
  # was sent. A thread that is only busy is waited for (hal-c2/hal-c2#644).
  @mc
  Scenario: A task whose end report failed settles on the retry
    Given the agent in "parent" delegated a task without waiting
    When the subagent completes and the first report of its end fails
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

  # Upstream #19058: the task result is the subagent's last answer even when its messages share a timestamp.
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

  # Upstream #19759: a finished task's status no longer repeats its result
  @mc
  Scenario: A finished task's status gives its result once
    Given the agent in "parent" delegated a task that finished with its answer
    When the agent asks for the task's status
    Then the answer is given once, not again as the latest answer
    And a later answer that differs from the result is still given

  @mc
  Scenario: A task's work state says whether its subagent works, waits on work it left, or has ended
    Given the agent in "parent" delegated a task whose subagent left a command running in the background
    When the agent in "parent" asks for the task's status
    Then the work state is "waiting_for_children"
    When the command ends and the subagent's turn about it ends
    Then the work state is "result_available"

  # Upstream #17028: a wake held for the user only the user can resume, so it is not work the task owes.
  @backlog @mc
  Scenario Outline: A task whose subagent's queued wakes are held for the user settles
    Given the agent in "parent" delegated a task whose subagent has a pull request wake queued
    When <event>
    And the subagent's queued wake is held for the user
    Then the task settles as "<status>" with that run as its result
    And its status says no child runs are pending
    And the held wake stays for the user to resume or discard

    Examples:
      | event                                   | status    |
      | the user stops the subagent             | cancelled |
      | the subagent's provider fails its turn  | failed    |

  @backlog @mc
  Scenario: A task left running behind a held wake settles when the MC starts
    Given a task whose subagent's turn ended and whose only queued wake is held for the user
    And the task is still "running"
    When the MC restarts
    Then the task settles with its subagent's last run as its result

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

  # The end of the interrupted turn would otherwise start it, for a task that is over.
  @mc
  Scenario: Cancelling a task cancels what its subagent has queued
    Given the agent in "parent" delegated a task that is still working
    And a message is queued behind the subagent's turn
    When the agent cancels the task
    Then the subagent's turn is interrupted and the message behind it cancelled
    And the task is cancelled and its delivery disposed

  # Upstream #21487: the task follows its run into queued, starting and its end, recovery puts
  # held runs back to idle, and cancelling removes the task's own run from a held queue.
  @backlog @mc
  Scenario: A task's status follows its subagent's queued run
    Given the agent in "parent" delegated a task whose run is queued behind the subagent's turn
    When the agent asks for the task's status
    Then the status says the task is queued
    When the run starts
    Then the status says the task is working

  # Upstream #21487
  @backlog @mc
  Scenario: Cancelling a task removes its run from a held queue and leaves the rest
    Given the agent in "parent" delegated a task whose run waits in a queue held for the user
    And another message waits in the same queue
    When the agent cancels the task
    Then the task's run is removed from the queue
    And the other message stays queued

  @mc
  Scenario Outline: A task that ends <ending> <fate> its subagent's open questions
    Given the agent in "parent" delegated a task whose subagent asked a question and kept working
    When the task ends <ending>
    Then the question is <state>

    Examples:
      | ending      | fate   | state                    |
      | cancelled   | closes | dismissed                |
      | interrupted | closes | dismissed                |
      | completed   | keeps  | still open to be answered |
      | failed      | keeps  | still open to be answered |

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

  # Upstream #25672: an acknowledgement written from a stale read put a settled run back to running.
  @mc @priority-high
  Scenario Outline: Acknowledging a task's delivery leaves a settled run settled
    Given a delegated task of "parent" finished with a delivered result
    And the caller's run <settled> just before the caller <command> the delivery
    Then the run stays <state>
    And the next run of "parent" can start

    Examples:
      | settled                        | command         | state     |
      | failed in the provider         | acknowledges    | failed    |
      | completed its checkpoint       | acknowledges    | completed |
      | completed its checkpoint       | disposes        | completed |

  @mc
  Scenario: The provider confirms it accepted a mailbox delivery
    Given a delegated task result was delivered into "parent" as a message
    When the provider accepts the delivery
    Then the message is recorded as accepted, separately from the agent reading it

  @mc
  Scenario: Delegated tasks can be requested with a command outside MCP
    When a client requests a delegated task for the active run of "parent"
    Then a subagent thread starts as if the agent had delegated it

  @mc
  Scenario Outline: A task's role frames the subagent's prompt
    When the agent in "parent" delegates the task "Check the schema" with <role>
    Then the subagent's first message is <prompt>

    Examples:
      | role        | prompt                                                              |
      | role "qa"   | "Act as the qa sub-agent for this task." and then the task          |
      | role "general" | the task unchanged                                               |
      | no role     | the task unchanged                                                  |

  @mc
  Scenario Outline: A task can name a provider by its kind instead of a configured instance
    Given "parent" runs on a "codex" instance that is <parent_instance>
    And another healthy "codex" instance exists
    When the agent in "parent" delegates a task naming the provider kind "codex"
    Then the subagent runs on <instance>

    Examples:
      | parent_instance | instance                        |
      | healthy         | the instance "parent" runs on   |
      | disabled        | the other healthy instance      |

  @mc
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

  @mc
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

  @mc
  Scenario: Repeating a delegation with the same request key starts one subagent
    Given the agent in "parent" delegated a task with request key "k1"
    When it repeats the request with request key "k1"
    Then no second subagent thread is started
    And it receives the same task id

  @mc
  Scenario: Reading a finished subagent's answer acknowledges its delivery
    Given a delegated task of "parent" finished with an answer that fits one read
    When the agent in "parent" reads the subagent's thread from the start
    Then the task's delivery is "acknowledged" and "parent" is not woken for it

  @mc
  Scenario: Reading one earlier message of a finished subagent does not acknowledge its result
    Given a delegated task of "parent" finished after a progress message
    When the agent in "parent" reads just the progress message of the subagent's thread
    Then the task's delivery is still pending

  @mc
  Scenario: Waiting on a subagent's thread does not acknowledge its delivery
    Given a delegated task of "parent" finished
    When the agent in "parent" waits on the subagent's thread
    Then the wait reports only the status
    And the task's delivery is still pending

  # Dropped: upstream #22581 replaced this with the scenario below, which the MC carries.
  @mc @dropped
  Scenario: Cancelling a task whose subagent has nothing running or in the background is refused
    Given the agent in "parent" delegated a task that is not finished and whose subagent has nothing running or in the background
    When the agent cancels the task
    Then the tool fails with code "task_not_cancellable"

  # Upstream #22581: a task left running with no run of its subagent bound to it can never
  # finish, so cancelling it clears it instead of being refused.
  @mc @priority-high
  Scenario: Cancelling a task whose subagent has nothing running or in the background clears it
    Given the agent in "parent" delegated a task that is not finished and whose subagent has nothing running or in the background
    When the agent cancels the task
    Then the tool reports the task "cancelled"
    And the task, its node and its turn item are "cancelled"

  # Upstream #22581, #22653: Stop on a subagent that was never given a run clears its task on
  # the caller even while the caller is idle, whatever else the subagent is doing.
  @mc @shared @backlog-desktop @backlog-mobile @backlog-tui @priority-high
  Scenario: Stopping a stuck subagent clears its task even when the caller is idle
    Given "parent" is idle and lists a delegated task as running
    And no run of the subagent was ever bound to that task
    When the user stops the subagent
    Then the task, its node and its turn item are "cancelled"
    And "parent" is not woken with a result

  # Upstream #22653: a subagent whose run is bound to the task keeps its normal settlement.
  @mc
  Scenario: Stopping a subagent whose run belongs to the task settles it the usual way
    Given the agent in "parent" delegated a task whose subagent is running its turn
    When the user stops the subagent
    Then the subagent's turn is interrupted
    And the task settles from that turn's outcome and "parent" is woken once

  # Upstream #22653: Stop on a task that already ended sends its state again, so a client
  # with a stale copy stops showing it as running.
  @backlog @mc @shared
  Scenario: Stopping a task that already ended brings a stale client up to date
    Given a client still shows a delegated task of "parent" as running
    And the task already ended as "cancelled"
    When the user stops the subagent
    Then the client shows the task as "cancelled"

  # Upstream #22653: cancelling a task whose subagent's run already ended stops the subagent
  # first, so nothing else on it keeps running.
  @mc
  Scenario: Cancelling a task whose subagent's run ended stops the subagent
    Given the agent in "parent" delegated a task whose subagent's run ended with other work still going
    When the agent cancels the task
    Then the subagent's work is stopped
    And the task is "cancelled"

  # Dropped: the wake carries the worker's whole result in a <delegated_task_result> envelope,
  # proved by "The parent hears the subagent's result" in timeline/plans-and-subagents.feature. A pointer to task_status would cost the
  # agent a round trip and lose the result when the task is disposed.
  @dropped @mc
  Scenario Outline: The message that wakes the caller names the finished tasks and how to read them
    Given the turn of "parent" ended while <tasks> were still working
    When <tasks> finish
    Then the agent of "parent" is woken with "<text>"

    Examples:
      | tasks                         | text                                                                                                                |
      | task "task-1"                 | Delegated task task-1 reached a terminal state. Use task_status with taskId task-1 to read the result.             |
      | tasks "task-1" and "task-2"   | Delegated tasks task-1, task-2 reached terminal states. Use task_status with each taskId to read the results.      |

  # Upstream #22117: results come in the completion message, not a history handoff, which could
  # fail a long parent conversation. Results within the budget stay whole in the message.
  # Dropped: as with the scenario above, the wake carries the whole result. Sending only a
  # pointer for large ones costs the agent a round trip and loses the result once the task is disposed.
  @dropped @mc
  Scenario: A task result too large for the wake message is left for task_status
    Given the agent in "parent" delegated a task titled "Audit deps"
    When the task completes with a result larger than 16,000 bytes
    Then "parent" is woken with the task's title and status
    And the message says to read the whole result with task_status
    And the result is kept intact for task_status

  @mc
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

  @mc
  Scenario: A task set to wake only an idle caller does not interrupt a caller that is still working
    Given the agent in "parent" delegated a task that wakes it only once it is idle
    When the subagent completes while the turn of "parent" is still running
    Then "parent" is not woken and nothing is queued for it
    And the result can be read from the task's status

  @mc
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

  @mc
  Scenario: A task that finishes while a wake is still queued joins that wake
    Given a wake for the finished task "one" of "parent" is queued behind a running turn
    When task "two" of the same turn finishes
    Then no second wake is queued
    And the queued wake now names "one" and "two"

  @mc
  Scenario: A task that finishes while the wake turn runs is delivered in one follow-up wake
    Given "parent" is running the turn that woke it for task "one"
    When tasks "two" and "three" of the same original turn finish
    Then they are not added to the running wake
    And when that turn ends "parent" is woken once more, for "two" and "three" together

  # Dropped (#892): a result that landed after the second wake reached no one, though
  # the agent is told every task wakes it when done.
  @mc @dropped
  Scenario: A caller's turn is woken at most twice for the tasks it started
    Given the tasks of one turn of "parent" already woke it twice
    When another task of that turn finishes
    Then "parent" is not woken a third time
    And the task's result stays readable from its status

  @mc
  Scenario: Every task that finishes after the caller's last wake ended wakes it again
    Given the tasks of one turn of "parent" already woke it twice
    When "three" and then "four" finish, each after the wake before it ended
    Then "parent" is woken four times, once for each task

  @mc
  Scenario: Completions that land while the caller is busy share one wake, however many came before
    Given the tasks of one turn of "parent" already woke it twice
    When "three" and "four" complete afterwards, while "parent" works on another turn
    Then "parent" is woken again for them
    And completions that arrive together share one wake turn

  @mc
  Scenario: Each delegated result reaches its caller exactly once
    Given the agent in "parent" delegated tasks "one", "two", "three" and "four" without waiting
    And "parent" was woken for the completion of "one"
    When "two" and "three" complete afterwards, while "parent" works on another turn
    And "four" finishes after the wake for them ended
    Then each task's result reached "parent" in exactly one wake turn
    And every task's delivery is "delivered"

  @mc
  Scenario: A task that finishes after its siblings' wakes were cancelled is still woken
    Given the agent in "parent" delegated tasks "one", "two" and "three" without waiting
    When task "one" of the same turn finishes
    And the agent acknowledges the result of "one"
    And task "two" of the same turn finishes
    And the agent acknowledges the result of "two"
    And task "three" of the same turn finishes
    Then a wake for task "three" is queued

  @mc
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

  @mc
  Scenario: Stopping the caller's turn stops its tasks from waking it later
    Given the agent in "parent" delegated tasks "one" and "two" without waiting
    When the user interrupts the turn of "parent"
    And "one" and "two" finish afterwards
    Then "parent" is not woken for either
    And a wake already queued for that turn is cancelled

  # Upstream #15331: stopping a wake turn left the tasks it delegated able to wake the caller again;
  # both sets are stopped now.
  @mc @backlog
  Scenario: Stopping a wake turn also keeps the tasks it delegated from waking the caller
    Given "parent" was woken to hear that task "one" finished
    And during that wake it delegated task "two" without waiting
    When the user interrupts the turn of "parent"
    And "two" finishes afterwards
    Then "parent" is not woken for "two"
    And the results of "one" and "two" can still be read

  # Upstream #20310: Stop on the parent cancels a follow-up task left running after its
  # subagent finished, when the subagent has no run, request or background work left.
  @mc @backlog
  Scenario: Stopping the caller ends a task left running after its subagent finished
    Given the agent in "parent" sent a follow-up to the task "one"
    And the subagent of "one" has finished with nothing running, queued or waiting
    But "one" still shows as running on "parent"
    When the user stops "parent"
    Then the task "one" is cancelled
    And a task whose subagent is still working keeps running

  # Upstream #23886: the Stop button stopped the thread but left subagents delegated in
  # earlier turns running, with their completions muted, so the parent never heard back.
  @mc @priority-high
  Scenario: Stopping a thread stops the subagents it delegated in earlier turns
    Given the agent in "parent" delegated task "one" in an earlier turn
    And the subagent of "one" is still working
    When the user presses Stop on "parent"
    Then the subagent of "one" is stopped
    And the task "one" is cancelled

  # Upstream #23886: a Stop that changes nothing on the thread still stops its subagents.
  @mc @priority-high
  Scenario: Pressing Stop again on a stopped thread stops subagents left running
    Given "parent" is stopped but the subagent of its task "one" is still working
    When the user presses Stop on "parent" again
    Then the subagent of "one" is stopped

  @mc
  Scenario Outline: Acknowledging tasks of a queued wake trims or cancels the wake
    Given a wake for the finished tasks "one" and "two" of "parent" is queued
    When the agent <reads>
    Then the queued wake <outcome>

    Examples:
      | reads                                   | outcome                     |
      | acknowledges the result of "one"        | names only "two"            |
      | acknowledges the results of both tasks  | is cancelled and never runs |
      | disposes the delivery of both tasks     | is cancelled and never runs |

  @mc
  Scenario Outline: Delivery commands only apply to tasks the MC started for that thread
    Given a subagent that the provider of "parent" started by itself
    When a client tries to <action> for that subagent
    Then the command fails saying it is not an app-owned task of thread "parent"

    Examples:
      | action                              |
      | acknowledge its completion delivery |
      | dispose its completion delivery     |
      | change its wake policy              |

  @mc
  Scenario: Setting the wake policy a task already has is refused
    Given the agent in "parent" delegated task "task-1" that always wakes it
    When the wake policy of "task-1" is set to always again
    Then the command fails with "Delegated task task-1 already wakes the parent with completionWake always."

  @mc
  Scenario Outline: Switching a finished task to always wake the caller
    Given a task of "parent" that wakes it only once idle finished while its turn was running
    And the turn of "parent" <state>
    When the task's wake policy is changed to always
    Then <outcome>

    Examples:
      | state            | outcome                                                              |
      | is still running | the result is delivered to "parent" now                              |
      | has ended        | no wake is sent and the result stays readable from the task's status |

  @mc
  Scenario Outline: A delegated task needs a turn of the caller that is still active
    When a client requests a delegated task for <target> of "parent"
    Then the command fails saying <reason>

    Examples:
      | target                                             | reason                                         |
      | a run that already ended                           | the parent run is not active                   |
      | the active run and a node that is not part of it   | the parent node is not part of the active run  |

  @mc
  Scenario Outline: What a task's result says when the subagent left no answer
    When the subagent's turn <ending>
    Then the task's result reads "<result>"

    Examples:
      | ending                                                    | result                                             |
      | completes without an assistant message                    | Child task completed without an assistant result.  |
      | is interrupted without an assistant message               | Child task ended with status interrupted.          |
      | fails with "Rate limit reached" after it already answered | Rate limit reached                                 |

  @mc
  Scenario: A task whose subagent is waiting on tasks of its own is not finished yet
    Given the agent in "parent" delegated a task
    And the subagent's turn ended while a task it delegated itself is still working
    When the agent in "parent" asks for the task's status
    Then the work state is "waiting_for_children"
    When the subagent's own task is done and the subagent's turn about it ends
    Then the work state is "result_available"
    And the task summary is the answer of the subagent's turn about its own task

  @mc
  Scenario: A subagent the provider started without a title or prompt is named after its parent
    Given "parent" is titled "Fix the parser"
    When the provider of "parent" starts its second subagent with neither a title nor a prompt
    Then the subagent's thread is titled "Fix the parser subagent 2"

  @mc
  Scenario Outline: A task whose subagent still owes work is not finished yet
    Given the agent in "parent" delegated a task
    And the subagent's turn ended while <owed>
    When the agent in "parent" asks for the task's status
    Then the task is still running and the work state is "<state>"

    Examples:
      | owed                                                              | state                |
      | a command it started is still running in the background           | waiting_for_children |
      | a task it delegated finished but that result has not reached it   | working              |

  # Upstream #22709: the task was only looked at again when a run of the subagent ended, so
  # work that settled later left it running until the MC restarted.
  @mc @priority-high
  Scenario Outline: A task finishes when the work its subagent left behind settles
    Given the agent in "parent" delegated a task
    And the subagent answered "Done" while <owed>
    When that work settles
    Then the task finishes with "Done"
    And "parent" is woken once with that result

    Examples:
      | owed                                               |
      | a command it started was running in the background |
      | a task it delegated itself was still running       |

  @mc
  Scenario: A turn that only handled a monitor update is not the task's result
    Given the agent in "parent" delegated a task
    And the subagent answered "Done: 3 files" with a turn to handle an update from a monitor queued behind it
    When that turn ends without a word
    Then the task summary is "Done: 3 files"

  @mc
  Scenario: A rolled-back turn of the subagent is not the task's result
    Given the agent in "parent" delegated a task
    And the subagent answered "First" and then "Second", with a third turn still working
    And the subagent's second turn was rolled back before the task settled
    When the third turn ends without a word
    Then the task summary is "First"

  # hal-c2/hal-c2#508: a turn that leaves work running is not the subagent's end.
  @mc
  Scenario: A subagent's own later turn that finishes its background work delivers the task's result
    Given the agent in "parent" delegated a task whose subagent left a command running in the background
    When the command ends and the subagent's turn about it ends
    Then "parent" receives one result message, with the answer of the subagent's turn about the command
    And no result message to "parent" says "The dev server is running."

  # Codex and Claude end the work's item before the turn it wakes is queued.
  @mc
  Scenario: A task is not settled between its subagent's background work ending and the turn that work wakes
    Given the agent in "parent" delegated a task whose subagent left a command running in the background
    When the command ends and the subagent's turn about it ends
    Then the task ended when its child's turn did
    And the task summary is the answer of the subagent's turn about the command

  @mc
  Scenario: A Grok subagent's background work ending settles its task with its last answer
    Given the agent in "parent" delegated a task to Grok whose subagent left work running in the background
    When the agent in "parent" asks for the task's status
    Then the work state is "waiting_for_children"
    When Grok reports the subagent's background work ended
    Then "parent" receives a system message carrying the delegated task result "Hello from acp"

  # hal-c2/hal-c2#40: the end of the subagent's turn never reached its caller.
  @mc
  Scenario: A task whose end report was lost settles without a restart
    Given the agent in "parent" delegated a task
    And the subagent completed with "Done", and the report of its end was lost
    When the subagent's session is released and the MC's periodic check runs
    Then "parent" receives a system message carrying the delegated task result "Done"
    And the lost report, arriving after all, does not deliver it again

  @mc
  Scenario: Cancelling a task that waits on background work stops that work
    Given the agent in "parent" delegated a task whose subagent left a command running in the background
    When the agent cancels the task
    Then the task is cancelled and its delivery disposed
    And the subagent's command is stopped

  @mc
  Scenario: A subagent the provider started is titled from its prompt, cut to 72 characters
    When the provider of "parent" starts a subagent with no title and a prompt of 100 characters
    Then the subagent's thread is titled with the prompt's first 69 characters followed by "..."

  @mc
  Scenario: A subagent starts awake whatever state its parent is in
    Given thread "parent" is snoozed
    When the provider of "parent" starts a subagent
    Then the subagent's thread is not snoozed, settled or archived
    And it has never been visited

  @mc
  Scenario: A provider-started subagent's prompt is shown as sent by its parent thread
    When the provider of "parent" starts a subagent with the prompt "Check the tests"
    Then the subagent's thread opens with the message "Check the tests" written by the agent
    And the message names "parent" as the thread that sent it

  @mc
  Scenario: Each review round is a new delegated task
    Given a delegated review task has finished
    When the parent wants the child to review again
    Then the instructions tell it to start a new delegated task with the full context and a new request id
    And cancelling the finished task leaves later runs of the child thread alone

  # Upstream #25359: a "one child per named model" line in the instructions made agents turn a
  # request for 20 workers on one model into one worker. The MC's instructions never had it.
  @mc @priority-low
  Scenario: An agent asked for several workers on the same model is not told to start just one
    When the user asks an agent for 20 workers on the same model
    Then nothing in the instructions given to the agent limits it to one delegated task per model

  # Upstream #17696: a message to a finished subagent reused its task, so the follow-up's
  # result overwrote the first one or was never delivered.
  @backlog @mc
  Scenario: A follow-up sent to a finished subagent is a task of its own
    Given "parent" delegated "task-1", which finished with the answer "Found 3 bugs"
    When "parent" sends the subagent "Fix them" in the same child thread
    Then a new task tracks the follow-up in that thread
    And "task-1" still finishes with "Found 3 bugs"
    And the follow-up's status, result and completion reach "parent" on their own

  @backlog @mc
  Scenario: Reading a follow-up task gives its own run's result
    Given a finished subagent's thread ran "task-1" and then the follow-up "task-2"
    When "parent" asks for the status and result of "task-1"
    Then it gets "task-1"'s run, not the later one
    And a follow-up continued after a restart stays the task it was

  # Upstream #19019: a message steered into a running subagent run opens no task.
  @mc
  Scenario: A message steered into a running subagent does not leave a task waiting
    Given a subagent is running a turn that no task is waiting on
    When the parent sends it a message that steers the running turn
    Then the parent is told the message was steered
    And no task is opened for it
    And the parent is not shown waiting on the subagent

  # Upstream #19801: delegated children no longer watch pull requests (refusing their watch is
  # source-control/pull-request-threads.feature); they hand the pull request back to the caller.
  @backlog @mc
  Scenario: A subagent's result names the pull request for its caller to watch
    Given the subagent of "parent" opened pull request 42 and its checks are still running
    When the subagent finishes its task
    Then the result delivered to "parent" names pull request 42, its head commit and that its checks are pending

  # Upstream #20025: a delegated completion no longer reverts a finished parent run or clears its checkpoint.
  @mc @priority-high
  Scenario: A subagent finishing while its caller checkpoints leaves the caller's run finished
    Given the run of "parent" is finishing and taking its checkpoint
    When the subagent of "parent" finishes at that moment
    Then the run of "parent" stays completed with its checkpoint
    And the subagent's result is delivered to "parent"

  # Upstream #16595: a subagent's options merge with the caller's when the model is inherited;
  # an empty list clears them and a new provider or model starts without them.
  @mc
  Scenario: A subagent keeps fast mode when its task sets only the effort
    Given "parent" runs with fast mode on
    When "parent" delegates a task that sets the reasoning effort to "high"
    Then the subagent runs with effort "high" and fast mode on

  # Upstream #16595
  @mc
  Scenario: A subagent on another model starts without the caller's options
    Given "parent" runs with fast mode on
    When "parent" delegates a task on another model
    Then the subagent runs without fast mode
