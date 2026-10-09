# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (plan.updated, subagent.updated, proposed_plan, todo_list, subagent, handoff, fork, compaction, thread_created, delegated_task.request, delegated_task.wake-policy, delegated_task.completion-delivery.acknowledge, delegated_task.completion-delivery.dispose)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (proposed_plan, todo_list)
#   apps/server-ex/lib/hal_c2/orchestration/delegation.ex (delegate_task, completion wake, no answer)
#   apps/server-ex/lib/hal_c2/orchestration.ex (message_item: a message with a notification is a notification item; users_run)
#   apps/server/src/orchestration-v2/Notification.ts (notificationTurnItem)
#   apps/web/src/session-logic.ts (notification work rows, getUserQueuedThreadRuns)
#   apps/desktop-qt/src/native/TimelineModel.cpp (noticeOf: notification rows, and results stored as user messages)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (fork marker)
#   apps/web/src/components/chat/ProposedPlanCard.tsx
#   apps/web/src/proposedPlan.ts (stripDisplayedPlanMarkdown)
#   apps/web/src/components/chat/ComposerPlanFollowUpBanner.tsx
#   apps/web/src/components/chat/ComposerPrimaryActions.tsx (Refine, Implement, Implement in a new thread)
#   apps/web/src/components/chat/ComposerTasksBadge.tsx
#   apps/web/src/components/chat/V2LifecycleRow.tsx
#   apps/web/src/components/chat/agentSpawnSummary.ts
#   apps/web/src/components/chat/MessagesTimeline.tsx (Subagent of, Open parent thread, Sent by another agent, lifecycle rows)
#   apps/tui/src/proposedPlan.ts
#   apps/desktop-qt/src/native/ComposerController.cpp (a plan is offered once its turn is over)
#   apps/tui/src/orchestrationV2Adapter.ts (Proposed plan, Updated plan, subagent progress, Forked thread, Transferred context, Created thread)
#   apps/tui/src/components/ChatView.tsx (Implement plan)
#   apps/web/src/components/AgentsPanel.tsx at d58daf4f5^ (the Agents tab: status, elapsed, activity)
#   apps/server-ex/lib/hal_c2/projection/background_work.ex (running commands)
#   apps/desktop-qt/src/native/AgentsModel.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/AgentsPanel.qml
#   apps/desktop-qt/tests/native/features/AgentsSteps.cpp

Feature: Plans and subagents
  An agent in plan mode proposes a plan the user can refine or implement. An agent can
  also hand work to subagents, whose progress shows in the parent's timeline.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # TUI: implemented in apps/tui/src/proposedPlan.ts
  @shared @backlog-mobile
  Scenario: A proposed plan appears as a card titled by its first heading
    When the agent proposes a plan whose first heading is "Add a tax line"
    Then the plan card is titled "Add a tax line"
    And a plan without a heading is titled "Proposed plan"

  @shared @backlog-mobile
  Scenario: A plan card does not repeat its title
    When the agent proposes a plan that opens with the heading "Add a tax line"
    Then the plan card is titled "Add a tax line"
    And the plan's text starts with "- Add the line"

  # TUI: implemented in apps/tui/src/components/ChatView.tsx
  @shared @backlog-mobile
  Scenario: The user implements the proposed plan
    Given the agent has proposed a plan
    When the user implements the plan with no feedback
    Then the agent starts implementing it in this thread
    And the plan card is no longer offered

  @shared @backlog-mobile
  Scenario: The user refines the plan with feedback
    Given the agent has proposed a plan
    When the user sends "split the migration into its own step" as feedback
    Then the agent revises the plan
    And the thread stays in plan mode

  @desktop
  Scenario: No plan is offered while the agent is still working
    Given the agent is proposing a plan in the running turn
    Then no plan is offered

  @shared @backlog-mobile @backlog-tui
  Scenario: The user implements the plan in a new thread
    Given the agent has proposed a plan
    When the user implements the plan in a new thread
    Then a new thread starts implementing the plan
    And the planning thread keeps the plan

  @shared @backlog-mobile @backlog-tui
  Scenario: Starting the implementation thread fails
    Given the agent has proposed a plan
    And the environment cannot start a new thread
    When the user implements the plan in a new thread
    Then the user is told "Could not start implementation thread"

  @shared @backlog-mobile @backlog-tui
  Scenario Outline: The user keeps a copy of the plan
    Given the agent has proposed a plan
    When the user <action>
    Then <result>

    Examples:
      | action                               | result                                             |
      | copies the plan                      | the plan's markdown is on the clipboard            |
      | downloads the plan                   | a markdown file of the plan is saved               |
      | saves the plan to "docs/tax-plan.md" | "docs/tax-plan.md" holds the plan in the workspace |

  @shared @backlog-mobile @backlog-tui
  Scenario: Saving the plan fails when the workspace is unavailable
    Given the agent has proposed a plan
    And the thread's workspace is unavailable
    When the user saves the plan to the workspace
    Then the user is told "Workspace path is unavailable"

  @mc
  Scenario: A delegated task appears in the parent's timeline
    Given the agent is working
    When the agent delegates "write the tax tests" to a subagent
    Then a subagent thread starts with only that task
    And the parent's timeline shows the subagent working

  @mc
  Scenario Outline: The parent hears the subagent's result
    Given the agent delegated a task and chose to <wait>
    When the subagent finishes <answer>
    Then the parent receives <message>
    And the parent's timeline shows a notification that the task finished, not a message of the user's

    Examples:
      | wait        | answer                | message                                |
      | carry on    | with "12 tests added" | "12 tests added" once it is free       |
      | wait for it | without an answer     | "(no answer)" once its own run is over |

  @mc
  Scenario Outline: A result waiting to wake the parent is the agent's, not the user's to change
    Given the agent delegated a task and chose to carry on
    And the subagent finishes with "12 tests added"
    When the user tries to <action> the result waiting to wake the parent
    Then the MC refuses, as the result is the agent's own message
    And the parent receives "12 tests added" once it is free

    Examples:
      | action |
      | edit   |
      | steer  |

  @shared @backlog-mobile
  Scenario: A delegated task's result shows as a notification, not a message of the user's
    Given a task the agent delegated as "Tax tests" finished
    When the user reads the parent thread
    Then the timeline says "Tax tests finished"
    And the result is not shown as a message of the user's

  @shared @backlog-mobile @backlog-tui
  Scenario: A result a thread stored as a user message still shows as a notification
    Given a thread stored the failed result of the delegated task "Tax tests" as a user message
    When the user reads the parent thread
    Then the timeline says "Tax tests failed"
    And the result is not shown as a message of the user's

  @shared @backlog-mobile
  Scenario Outline: A subagent's status is shown in the parent
    Given the agent has a subagent that is <status>
    Then the subagent is shown as "<label>"

    Examples:
      | status               | label            |
      | running              | Working          |
      | waiting on a request | Working          |
      | idle and resumable   | Idle · resumable |
      | completed            | Completed        |
      | failed               | Failed           |
      | cancelled            | Stopped          |

  @shared @backlog-mobile
  Scenario: The user moves between a subagent and its parent
    Given the agent has a subagent
    When the user opens the subagent's thread
    Then the thread says it is a subagent of the parent
    When the user opens the parent thread
    Then the parent thread is shown

  @mc @shared @backlog-mobile
  Scenario: A message from another agent says which thread it came from
    Given a subagent sent a message to its parent
    When the user reads the message in the parent thread
    Then it says which thread it came from
    And the user can open that thread

  @shared @backlog-mobile
  Scenario: The agent's own background wake-up is not a message from another agent
    Given the agent's background work woke it up
    When the user reads the parent thread
    Then the timeline says "Background activity updated"
    And nothing says a message was sent by another agent

  @shared @backlog-mobile @backlog-tui
  Scenario: A wake-up a thread stored as a user message is not from another agent either
    Given a thread stored the agent's own wake-up as a user message
    When the user reads the parent thread
    Then the timeline says "Background activity updated"
    And nothing says a message was sent by another agent

  @mc @shared @backlog-mobile
  Scenario: A subagent shows the model it runs on
    Given the agent delegated work to a subagent on the model "model-b"
    When the user looks at the parent's subagents
    Then the subagent is shown with "model-b"
    And the parent's model is not shown for it

  @mc @shared @backlog-mobile @backlog-tui
  Scenario: A finished subagent with work still running is shown as pending
    Given a subagent returned its result while background work it started is still running
    When the user looks at the parent thread
    Then the subagent's result is shown
    And its background work is still shown as running

  @mc @shared @backlog-mobile @backlog-tui
  Scenario: A subagent's approval request shows up in the parent thread
    Given a subagent asks for approval to run a command
    When the user looks at the parent thread
    Then the approval is listed there
    When the user answers it
    Then the subagent continues with the answer

  # TUI: implemented in apps/tui/src/orchestrationV2Adapter.ts
  @shared @backlog-mobile
  Scenario Outline: Changes to the thread's context are marked in the timeline
    When <event>
    Then the timeline marks "<marker>"

    Examples:
      | event                                  | marker            |
      | the conversation is forked             | Conversation fork |
      | the context is handed to another agent | Context handoff   |
      | the agent creates a thread             | Created thread    |
      | the context is compacted               | Context compacted |

  @desktop
  Scenario: The Agents tab lists the thread's subagents
    Given the agent started the subagents "Tax tests" and "Docs"
    And "Docs" finished 75 seconds after it started
    When the user opens the Agents tab
    Then the Agents tab lists "Tax tests" as "Working" and "Docs" as "Completed"
    And "Docs" is shown to have taken "1m 15s"

  @desktop
  Scenario: The Agents tab keeps what is running above what has finished
    Given the agent started the subagents "Docs" and "Tax tests"
    And "Docs" finished 75 seconds after it started
    And the agent is running the command "bun test cart"
    When the user opens the Agents tab
    Then the Agents tab lists, in order:
      | Tax tests     | Active   |
      | bun test cart | Active   |
      | Docs          | Finished |

  @desktop
  Scenario: The Agents tab says when each subagent finished, latest first
    Given the agent started the subagent "Lint" 90000 seconds ago
    And "Lint" finished 60 seconds after it started
    And the agent started the subagents "Tax tests" and "Docs"
    And "Docs" finished 30 seconds after it started
    And "Tax tests" finished 85 seconds after it started
    When the user opens the Agents tab
    Then the Agents tab lists, in order:
      | Tax tests | Finished |
      | Docs      | Finished |
      | Lint      | Finished |
    And "Tax tests" is shown to have ended "Completed at 9:59 AM"
    And "Lint" is shown to have ended "Completed yesterday at 9:01 AM"

  # A tab left open overnight: "Completed at" is yesterday's by morning.
  @desktop
  Scenario: The Agents tab's end times follow the day over midnight
    Given the agent started the subagent "Tax tests" 120 seconds ago
    And "Tax tests" finished 85 seconds after it started
    When the user opens the Agents tab
    And the day turns over
    Then the Agents tab redraws when each subagent ended
    And "Tax tests" is shown to have ended "Completed yesterday at 9:59 AM"

  # A laptop asleep over midnight wakes to a stream update before its timer fires.
  @desktop
  Scenario: The Agents tab's end times follow the day when the desktop wakes after midnight
    Given the agent started the subagent "Tax tests" 120 seconds ago
    And "Tax tests" finished 85 seconds after it started
    And the agent started the subagent "Lint" 5 seconds ago
    When the user opens the Agents tab
    And the day turns over while the desktop sleeps
    And the subagent finishes with "lint clean"
    Then the Agents tab redraws when each subagent ended
    And "Tax tests" is shown to have ended "Completed yesterday at 9:59 AM"

  @desktop
  Scenario: The Agents tab tells the time as the user set it
    Given the agent started the subagent "Docs" 90 seconds ago
    And "Docs" finished 75 seconds after it started
    And the user opens the Agents tab
    When the user prefers a 24-hour clock
    Then "Docs" is shown to have ended "Completed at 09:59"

  # A refreshed list would lose where the user had scrolled.
  @desktop
  Scenario: The Agents tab keeps its rows as work starts and ends
    Given the agent started the subagents "Tax tests" and "Docs"
    And the user opens the Agents tab
    When the agent is running the command "bun test cart"
    And the command finishes
    And the subagent finishes with "docs written"
    Then the Agents tab never started its list over

  @desktop
  Scenario: A subagent's elapsed time moves only while the Agents tab shows
    Given the agent started the subagent "Tax tests" 12 seconds ago
    When the user opens the Agents tab
    Then "Tax tests" is shown to have taken "12s"
    When a second passes
    Then "Tax tests" is shown to have taken "13s"
    When the user switches to the Diff tab
    Then the Agents tab's times stand still

  @desktop
  Scenario: The Agents tab follows a subagent as it finishes
    Given the agent started the subagent "Tax tests" 12 seconds ago
    And the user opens the Agents tab
    When the subagent finishes with "12 tests added"
    Then the Agents tab lists "Tax tests" as "Completed" with "12 tests added"
    And the Agents tab's times stand still

  @desktop
  Scenario: The Agents tab lists the commands still running
    Given the agent is running the command "bun test cart"
    When the user opens the Agents tab
    Then the Agents tab lists the running command "bun test cart"
    When the command finishes
    Then the Agents tab lists no running command

  @desktop
  Scenario: A subagent's thread opens from the Agents tab
    Given the agent started the subagent "Tax tests" 12 seconds ago
    And the user opens the Agents tab
    When the user opens "Tax tests" from the Agents tab
    Then the subagent's thread is shown
