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
#   apps/web/src/components/chat/SubagentTooltipContent.tsx (model, status, elapsed, project, branch, 280-character preview)
#   packages/shared/src/model.ts (formatModelSlugName: a model id written as a name)
#   apps/web/src/components/ChatView.tsx (the implementation thread's title and prompt)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Subagent of, Open parent thread, Sent by another agent, Sent by automation, Inherited, Synthetic, lifecycle rows)
#   apps/tui/src/proposedPlan.ts
#   apps/desktop-qt/src/native/ComposerController.cpp (a plan is offered once its turn is over)
#   apps/tui/src/orchestrationV2Adapter.ts (Proposed plan, Updated plan, subagent progress, Forked thread, Transferred context, Created thread)
#   apps/tui/src/components/ChatView.tsx (Implement plan)
#   apps/web/src/components/AgentsPanel.tsx at d58daf4f5^ (the Agents tab: status, elapsed, activity)
#   apps/server-ex/lib/hal_c2/projection/background_work.ex (running commands)
#   apps/desktop-qt/src/native/AgentsModel.cpp
#   apps/mobile/src/features/threads/thread-subagent-group.tsx (several subagents grouped, summary)
#   apps/mobile/src/features/threads/ThreadAgentsSheet.tsx (the turn's subagents, provider-managed rows)
#   packages/client-runtime/src/state/threadSubagents.ts (the status segment, the latest turn's roster)
#   packages/client-runtime/src/state/subagentDisplay.ts (the group's counts, a subagent's displayed title)
#   apps/web/src/components/chat/MessagesTimeline.tsx (V2SubagentGroup: the group's entry, avatars, span)
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

  @backlog @desktop
  Scenario: A plan follow-up that cannot be sent is taken back and reported
    Given the agent has proposed a plan
    And the environment refuses new messages
    When the user sends "split the migration into its own step" as feedback
    Then the feedback is no longer shown as a sent message
    And the thread shows the reason, or "Failed to send plan follow-up." when none is given

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

  @desktop @backlog
  Scenario: A plan's Summary heading is not repeated in its card
    When the agent proposes a plan whose first heading is "Add a tax line" followed by a "Summary" heading
    Then the plan card is titled "Add a tax line"
    And the plan's text starts after the "Summary" heading

  @desktop @backlog
  Scenario Outline: A long plan is shown as a preview that can be opened
    Given the agent has proposed a plan <size>
    Then the plan card shows <shown>

    Examples:
      | size                            | shown                                       |
      | of 30 short lines               | its first 10 lines followed by an ellipsis  |
      | of 1,000 characters on 5 lines  | its first 10 lines followed by an ellipsis  |
      | of 15 short lines               | the whole plan and no way to collapse it    |

  @desktop @backlog
  Scenario: A previewed plan is opened and closed again
    Given the agent has proposed a plan of 30 short lines
    When the user chooses "Expand plan"
    Then the whole plan is shown
    When the user chooses "Collapse plan"
    Then the plan returns to its preview

  @desktop @backlog
  Scenario Outline: A plan's copy is named after its title
    Given the agent has proposed a plan titled "<title>"
    When the user downloads the plan
    Then the file is named "<file>"

    Examples:
      | title                  | file              |
      | Add a tax line         | add-a-tax-line.md |
      | Fix `cart.ts`, finally | fix-cart-ts-finally.md |
      | (no heading)           | plan.md           |

  @desktop @backlog
  Scenario: Saving the plan to the workspace starts from its file name
    Given the agent has proposed a plan titled "Add a tax line"
    When the user chooses to save the plan to the workspace
    Then the user is asked for a path relative to the workspace
    And the path starts as "add-a-tax-line.md"

  @desktop @backlog
  Scenario: Saving the plan to the workspace needs a path
    Given the agent has proposed a plan
    And the user is asked where in the workspace to save it
    When the user clears the path and saves
    Then the user is told "Enter a workspace path"
    And nothing is saved

  @desktop @backlog
  Scenario: A plan saved to the workspace says where
    Given the agent has proposed a plan
    When the user saves the plan to "docs/tax-plan.md"
    Then the user is told "Plan saved to workspace" with "docs/tax-plan.md"

  @desktop @backlog
  Scenario: A plan that cannot be written says so and keeps the dialog
    Given the agent has proposed a plan
    And the workspace refuses the write
    When the user saves the plan to "docs/tax-plan.md"
    Then the user is told "Could not save plan" with the reason
    And the user can try another path

  @desktop @backlog
  Scenario: A plan that cannot reach the clipboard says so
    Given the agent has proposed a plan
    And the clipboard refuses the copy
    When the user copies the plan
    Then the user is told "Could not copy plan" with the reason

  @desktop @backlog
  Scenario Outline: A plan is saved as the same text however it is kept
    Given the agent has proposed a plan with trailing blank lines
    When the user <action>
    Then the plan is kept whole with its title and ends with a single newline

    Examples:
      | action                           |
      | copies the plan                  |
      | downloads the plan               |
      | saves the plan to the workspace  |

  @desktop @backlog
  Scenario Outline: A plan implemented in a new thread names the thread after the plan
    Given the agent has proposed a plan <titled>
    When the user implements the plan in a new thread
    Then the new thread is titled "<title>"

    Examples:
      | titled                   | title                 |
      | titled "Add a tax line"  | Implement Add a tax line |
      | with no heading          | Implement plan        |

  @desktop @backlog
  Scenario: Implementing a plan with no feedback sends the plan as the user's message
    Given the agent has proposed a plan
    When the user implements the plan with no feedback
    Then the user's message reads "PLEASE IMPLEMENT THIS PLAN:" followed by the plan
    And the thread leaves plan mode

  @backlog @desktop
  Scenario: A plan that is ready is announced above the composer by its title
    Given the agent has proposed a plan headed "Add a tax line"
    Then the composer says "Plan ready" with "Add a tax line"
    And a plan with no heading is announced as "Plan ready" alone

  @backlog @desktop
  Scenario: Typing feedback turns implementing the plan into refining it
    Given the agent has proposed a plan
    Then the composer offers to implement the plan
    When the user types "split the migration into its own step"
    Then the composer offers to refine the plan instead
    When the user clears the composer
    Then the composer offers to implement the plan again

  @backlog @desktop
  Scenario: The agent's task list is summed up above the composer
    Given the agent's task list has the steps "Add the tax line", "Write tests" and "Update docs"
    And "Add the tax line" is finished and "Write tests" is in progress
    Then the composer shows "Tasks" with the current step "Write tests" and 1 of 3 done

  @backlog @desktop
  Scenario: The task summary opens to every step, its status and how long it took
    Given the agent finished "Add the tax line" in 42 seconds and is working on "Write tests"
    And "Update docs" has not started
    When the user opens the task summary
    Then "Add the tax line" is listed as completed with "42s"
    And "Write tests" is listed as running with "now"
    And "Update docs" is listed as pending with no time

  @backlog @desktop
  Scenario Outline: The task summary is not shown when there is nothing for it to say
    Given <situation>
    Then the composer shows no task summary

    Examples:
      | situation                                                    |
      | the agent has reported no task list                          |
      | the agent's task list is open and an approval comes in       |
      | the agent's task list is open and the agent asks a question  |

  @backlog @desktop
  Scenario: An open task list closes when the user changes thread
    Given the user opened the task summary in thread A
    When the user switches to thread B and back to thread A
    Then the task list is closed and only its summary is shown

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

  @shared @backlog-mobile @backlog-tui
  Scenario: A finished subagent shows its result, a working one its latest progress
    Given a subagent that reported "Reading the tax code" and then finished with "12 tests added"
    Then the subagent's row reads "12 tests added"

  @shared @backlog-mobile @backlog-tui
  Scenario: A working subagent shows its latest progress
    Given a subagent that is still working after reporting "Reading the tax code"
    Then the subagent's row reads "Reading the tax code"

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

  @desktop @backlog
  Scenario: A message sent by a scheduled task says so and leads to the task
    Given a scheduled task sent a message to the thread
    When the user reads the message in the thread
    Then it says "Sent by automation"
    And the user can open that scheduled task from it

  @desktop @backlog
  Scenario: A message sent by automation that no task owns still says so
    Given a message was sent to the thread by automation that is not a scheduled task
    When the user reads the message in the thread
    Then it says "Sent by automation"

  @desktop @backlog
  Scenario: A message from another agent without a known thread still says so
    Given another agent sent a message whose thread is not known
    When the user reads the message in the thread
    Then it says "Sent by another agent"
    And it cannot be opened

  @desktop @backlog
  Scenario Outline: Work a fork carried over or the system added is marked as such
    Given the timeline shows work that <origin>
    Then the work is marked "<marker>"

    Examples:
      | origin                                    | marker    |
      | the fork's source thread did before the fork | Inherited |
      | HAL-C2 recorded rather than the agent     | Synthetic |

  @desktop @backlog
  Scenario: Inherited work says which thread it came from
    Given the timeline shows work that the fork's source thread did before the fork
    When the user opens the work
    Then it says which thread it came from

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

  # Legacy: packages/shared/src/model.ts (formatModelSlugName), apps/web/src/components/chat/SubagentTooltipContent.tsx
  @backlog @desktop
  Scenario Outline: A subagent's model is written the way a person would write its name
    Given the agent delegated work to a subagent on the model "<model>"
    When the user looks at the parent's subagents
    Then the subagent is shown with "<shown>"

    Examples:
      | model                         | shown                         |
      | gpt-5.4                       | GPT-5.4                       |
      | openai/gpt-5.4-mini           | openai/GPT-5.4-Mini           |
      | claude-opus-4-6               | Claude Opus 4.6               |
      | claude-opus-4-6[1m]           | Claude Opus 4.6[1m]           |
      | gemini-2.5-pro-preview-06-05  | Gemini 2.5 Pro Preview 06 05  |
      | custom/model-v2               | custom/model-v2               |
      | My Custom Model               | My Custom Model               |

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

  @desktop @backlog
  Scenario Outline: A context compaction says how it stands
    When the context compaction <state>
    Then the timeline marks "<marker>"

    Examples:
      | state                  | marker                      |
      | is in progress         | Compacting context          |
      | finishes               | Context compacted           |
      | fails                  | Context compaction failed   |
      | is cancelled           | Context compaction stopped  |
      | is interrupted         | Context compaction stopped  |

  @desktop @backlog
  Scenario Outline: A context compaction says what it did
    When the context compaction finishes <with>
    Then the marker's detail reads "<detail>"

    Examples:
      | with                                       | detail                  |
      | with the summary "Dropped old tool output" | Dropped old tool output |
      | from 120000 to 30000 tokens                | 120000 → 30000 tokens   |
      | knowing only that it ended at 30000 tokens | ? → 30000 tokens        |

  @desktop @backlog
  Scenario: A context handoff shows where the context came from and went
    Given the thread ran on "Claude · Opus" and then on "Codex · GPT"
    When the context is handed to "Codex · GPT"
    Then the marker shows "Claude" and "Codex" with their models
    And pointing at either names its provider and model

  @desktop @backlog
  Scenario: A context handoff that failed is marked as failed
    When the context handoff fails
    Then the marker "Context handoff" is shown as a failure

  @desktop @backlog
  Scenario Outline: A fork marker leads to the other end of the fork
    Given <situation>
    Then the timeline marks "<marker>"
    And the user can open the other thread with "<action>"

    Examples:
      | situation                               | marker                   | action                   |
      | this thread was forked from another     | Forked from conversation | Open source conversation |
      | another thread was forked from this one | Conversation fork        | Open fork                |

  @desktop @backlog
  Scenario: A created thread can be opened from where it was created
    When the agent creates the thread "Tax tests"
    Then the timeline shows "Created thread · Tax tests"
    And the user can open it with "Open chat"

  @desktop @backlog
  Scenario: A created thread shown as a resource opens as a card
    Given the agent created the thread "Tax tests" and the timeline shows it as a resource
    Then the card is titled "Tax tests"
    And the user can open the thread with "Open chat"

  @desktop @backlog
  Scenario: A thread created without a title is still named
    When the agent creates a thread that has no title
    Then the timeline shows "Created thread"

  @desktop @backlog
  Scenario: An interrupt shows what was asked for and when
    When the user interrupts the running turn with the message "stop, wrong branch"
    Then the timeline shows "Interrupt requested · stop, wrong branch" and the time
    When the run stops
    Then the timeline shows "Run interrupted" with the run's message

  @desktop @backlog
  Scenario Outline: A subagent's pointing card gives the facts of its work
    Given the agent has a subagent that is <status> and has <detail>
    When the user points at the subagent in the parent's timeline
    Then the card shows <shown>

    Examples:
      | status    | detail                                  | shown                                            |
      | running   | no model reported                       | "Not reported" in place of the model             |
      | running   | the model "model-b"                     | the model's name and how long it has worked      |
      | completed | a result of 400 characters              | its first 280 characters followed by an ellipsis |
      | running   | its own project                         | the subagent's project                           |
      | running   | its own branch, other than the parent's | the subagent's branch                            |
      | running   | its own worktree with no branch         | the worktree's folder name                       |

  @desktop @backlog
  Scenario: A subagent that only ended is not given a note instead of an answer
    Given a subagent ended with no answer and the note "Child task ended with status completed"
    Then the subagent row shows "Completed" and not that note

  @desktop @backlog
  Scenario: A subagent row shows its latest word while it works and its answer when it ends
    Given the agent has a subagent that reported the progress "reading cart.ts"
    Then the row shows "Working" and "reading cart.ts"
    When the subagent finishes with the result "12 tests added"
    Then the row shows "12 tests added" instead of the progress

  @desktop @backlog
  Scenario: A subagent without a thread cannot be opened
    Given the agent has a subagent that has not started a thread
    Then its row is shown with its status
    And the row cannot be opened

  # Legacy: apps/web/src/components/chat/MessagesTimeline.tsx (V2SubagentGroup)
  @backlog @desktop
  Scenario: Subagents started together are one group in the timeline that opens to its rows
    Given the agent started the subagents "Tax tests", "Docs" and "Lint" together
    Then the timeline shows one entry reading "3 subagents" with how many are working, done, failed, stopped or idle
    And the rows of the subagents are shown only once the user opens the entry
    And the entry stays open or closed the way the user left it while the thread is open

  # Legacy: packages/client-runtime/src/state/subagentDisplay.ts (summarizeSubagentStatuses)
  @backlog @desktop @mobile
  Scenario Outline: A group of subagents counts what is still working first and then the outcomes
    Given the agent started a group of subagents of which <states>
    Then the group reads "<summary>"

    Examples:
      | states                                                       | summary                                  |
      | two are working and one is done                              | 2 working · 1 done                       |
      | one is waiting for the user and one is not started yet       | 2 working                                |
      | two are done, one failed and one was stopped                 | 2 done · 1 failed · 1 stopped            |
      | one is working, one is done, one failed, one stopped, one idle | 1 working · 1 done · 1 failed · 1 stopped · 1 idle |

  # Legacy: apps/web/src/components/chat/MessagesTimeline.tsx (V2SubagentGroup, subagentGroupTiming)
  @backlog @desktop
  Scenario: A group of subagents shows one span from the first launch to the last finish
    Given the agent started the subagents "Tax tests" and "Docs" together
    And "Tax tests" started at 10:00:00 and finished at 10:01:00
    And "Docs" started at 10:00:10 and finished at 10:02:30
    When the user looks at the group
    Then the group shows a span of 2m 30s

  # Legacy: apps/web/src/components/chat/MessagesTimeline.tsx (subagentGroupTiming)
  @backlog @desktop
  Scenario: A group's span is withheld while a finished subagent has no end time
    Given the agent started the subagents "Tax tests" and "Docs" together
    And both have finished but the end time of "Docs" was not reported
    When the user looks at the group
    Then the group shows no span

  # Legacy: apps/web/src/components/chat/MessagesTimeline.tsx (V2SubagentGroup)
  @backlog @desktop
  Scenario: A group of subagents shows three avatars and how many more
    Given the agent started five subagents together
    When the user looks at the group
    Then it shows the avatars of the first three and "+2"

  # Legacy: packages/client-runtime/src/state/subagentDisplay.ts (formatSubagentDisplayTitle)
  @backlog @desktop @mobile
  Scenario Outline: A subagent's title is shown without its provider's prefix or task path
    Given a subagent whose title is "<title>"
    When the user sees it in the timeline, the lineage or the agents list
    Then it is shown as "<shown>"

    Examples:
      | title                       | shown     |
      | Subagent: Fix the cart      | Fix the cart |
      | /root/baz_qux               | Baz Qux   |
      | /root/team/review_docs/     | Review Docs |
      | Review the docs             | Review the docs |

  @backlog @mobile
  Scenario: Subagents started together are one group that opens to its rows
    Given the agent started the subagents "Tax tests", "Docs" and "Lint" together
    Then the timeline shows one entry reading "3 subagents" with how many are working, done or failed
    And the rows of the subagents are shown only once the user opens the entry

  @backlog @mobile
  Scenario: A lone subagent is shown as its own row without a group
    Given the agent started the subagent "Tax tests" alone
    Then the timeline shows the row of "Tax tests" directly

  @backlog @mobile
  Scenario Outline: The thread's status counts the subagents of the turn
    Given the agent started three subagents in this turn
    When <state>
    Then the thread's status says "<status>"

    Examples:
      | state                           | status                |
      | two of them are still working   | 2 of 3 agents working |
      | all three have finished         | 3 agents done         |

  @backlog @mobile
  Scenario: The thread's status says nothing about subagents once the turn has settled
    Given the agent started three subagents in this turn
    When the turn settles and every subagent has finished
    Then the thread's status does not mention subagents

  @backlog @mobile
  Scenario: The subagents of the turn are listed with their state and time
    Given the agent started the subagents "Tax tests" and "Docs" in this turn
    And "Docs" finished 75 seconds after it started
    When the user opens the subagents from the thread's status
    Then "Tax tests" is listed as working and "Docs" as completed
    And "Docs" is shown to have taken "1m 15s"

  @backlog @mobile
  Scenario: A thread's subagents are listed for the latest turn only
    Given the agent started the subagent "Tax tests" in the first turn
    And the agent started the subagent "Docs" in the second turn
    When the user opens the subagents of the thread
    Then only "Docs" is listed

  @backlog @mobile
  Scenario: A subagent the provider manages is listed but cannot be opened
    Given the agent has a subagent that the provider manages and that has no thread
    When the user opens the subagents of the thread
    Then the subagent is listed with its status
    And it says its work appears in the conversation
    And it cannot be opened

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
