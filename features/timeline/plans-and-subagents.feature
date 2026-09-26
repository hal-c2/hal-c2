# Sources:
#   packages/contracts/src/orchestrationV2.ts (plan.updated, subagent.updated, proposed_plan, todo_list, subagent, handoff, fork, compaction, thread_created, delegated_task.request, delegated_task.wake-policy, delegated_task.completion-delivery.acknowledge, delegated_task.completion-delivery.dispose)
#   apps/server-ex/lib/t3/orchestration/turn_writer.ex (proposed_plan, todo_list)
#   apps/server-ex/lib/t3/orchestration/delegation.ex (delegate_task, completion wake, no answer)
#   apps/server-ex/lib/t3/projection/timeline.ex (fork marker)
#   apps/web/src/components/chat/ProposedPlanCard.tsx
#   apps/web/src/components/chat/ComposerPlanFollowUpBanner.tsx
#   apps/web/src/components/chat/ComposerPrimaryActions.tsx (Refine, Implement, Implement in a new thread)
#   apps/web/src/components/chat/ComposerTasksBadge.tsx
#   apps/web/src/components/chat/V2LifecycleRow.tsx
#   apps/web/src/components/chat/agentSpawnSummary.ts
#   apps/web/src/components/chat/MessagesTimeline.tsx (Subagent of, Open parent thread, Sent by another agent, lifecycle rows)
#   apps/tui/src/proposedPlan.ts
#   apps/tui/src/orchestrationV2Adapter.ts (Proposed plan, Updated plan, subagent progress, Forked thread, Transferred context, Created thread)
#   apps/tui/src/components/ChatView.tsx (Implement plan)

Feature: Plans and subagents
  An agent in plan mode proposes a plan the user can refine or implement. An agent can
  also hand work to subagents, whose progress shows in the parent's timeline.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # TUI: implemented in apps/tui/src/proposedPlan.ts
  @shared @backlog
  Scenario: A proposed plan appears as a card titled by its first heading
    When the agent proposes a plan whose first heading is "Add a tax line"
    Then the plan card is titled "Add a tax line"
    And a plan without a heading is titled "Proposed plan"

  # TUI: implemented in apps/tui/src/components/ChatView.tsx
  @shared @backlog
  Scenario: The user implements the proposed plan
    Given the agent has proposed a plan
    When the user implements the plan with no feedback
    Then the agent starts implementing it in this thread
    And the plan card is no longer offered

  @shared @backlog
  Scenario: The user refines the plan with feedback
    Given the agent has proposed a plan
    When the user sends "split the migration into its own step" as feedback
    Then the agent revises the plan
    And the thread stays in plan mode

  @shared @backlog
  Scenario: The user implements the plan in a new thread
    Given the agent has proposed a plan
    When the user implements the plan in a new thread
    Then a new thread starts implementing the plan
    And the planning thread keeps the plan

  @shared @backlog
  Scenario: Starting the implementation thread fails
    Given the agent has proposed a plan
    And the environment cannot start a new thread
    When the user implements the plan in a new thread
    Then the user is told "Could not start implementation thread"

  @shared @backlog
  Scenario Outline: The user keeps a copy of the plan
    Given the agent has proposed a plan
    When the user <action>
    Then <result>

    Examples:
      | action                               | result                                             |
      | copies the plan                      | the plan's markdown is on the clipboard            |
      | downloads the plan                   | a markdown file of the plan is saved               |
      | saves the plan to "docs/tax-plan.md" | "docs/tax-plan.md" holds the plan in the workspace |

  @shared @backlog
  Scenario: Saving the plan fails when the workspace is unavailable
    Given the agent has proposed a plan
    And the thread's workspace is unavailable
    When the user saves the plan to the workspace
    Then the user is told "Workspace path is unavailable"

  @node
  Scenario: A delegated task appears in the parent's timeline
    Given the agent is working
    When the agent delegates "write the tax tests" to a subagent
    Then a subagent thread starts with only that task
    And the parent's timeline shows the subagent working

  @node
  Scenario Outline: The parent hears the subagent's result
    Given the agent delegated a task and chose to <wait>
    When the subagent finishes <answer>
    Then the parent receives <message>

    Examples:
      | wait        | answer                | message                                |
      | carry on    | with "12 tests added" | "12 tests added" once it is free       |
      | wait for it | without an answer     | "(no answer)" once its own run is over |

  @shared @backlog
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

  @shared @backlog
  Scenario: The user moves between a subagent and its parent
    Given the agent has a subagent
    When the user opens the subagent's thread
    Then the thread says it is a subagent of the parent
    When the user opens the parent thread
    Then the parent thread is shown

  # TUI: implemented in apps/tui/src/orchestrationV2Adapter.ts
  @shared @backlog
  Scenario Outline: Changes to the thread's context are marked in the timeline
    When <event>
    Then the timeline marks "<marker>"

    Examples:
      | event                                  | marker            |
      | the conversation is forked             | Conversation fork |
      | the context is handed to another agent | Context handoff   |
      | the agent creates a thread             | Created thread    |
      | the context is compacted               | Context compacted |
