# Sources:
#   apps/desktop-qt/src/native/ComposerController.cpp (turn: approvals, questions, plan, queue)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/chat/ComposerPendingApprovalPanel.tsx
#   apps/web/src/components/chat/ComposerQueuedMessages.tsx
#   apps/tui/src/approvals.ts (stale versus transient respond failure)
#   Shared domain: timeline/approvals-and-questions.feature, composer/queue-and-steer.feature and
#   timeline/plans-and-subagents.feature own what the answers do; this file owns that the Qt
#   shell reads the turn from the thread's stream and answers the node itself.

Feature: The desktop shell answers a thread's turn from its stream
  The Qt shell reads the pending approvals, questions, proposed plan and queued messages
  of the thread the window shows from that thread's stream, and sends the user's answers
  straight to the node.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop" whose agent is working

  Rule: Queued messages can be removed or turned into a steer

    @desktop
    Scenario: Queued messages are listed in the order they run
      Given "check the logs" and "update the docs" are queued
      Then the composer lists the queued messages "check the logs" and "update the docs"

    @desktop
    Scenario: Removing a queued message cancels its run
      Given "check the logs" and "update the docs" are queued
      When the user removes "check the logs" from the queue
      Then the node is asked to cancel the queued run of "check the logs"

    @desktop
    Scenario: A removal the node refuses is reported
      Given "check the logs" and "update the docs" are queued
      And the node refuses "queued-run.cancel" with "run already started"
      When the user removes "check the logs" from the queue
      Then the user sees an "error" toast "Failed to remove the queued message." saying "run already started"

    @desktop
    Scenario: A queued message can steer the running turn
      Given "check the logs" and "update the docs" are queued
      When the user steers the running turn with the queued "update the docs"
      Then the node is asked to steer the running turn with the queued run of "update the docs"

    @desktop
    Scenario: A steer the node refuses is reported
      Given "check the logs" and "update the docs" are queued
      And the node refuses "queued-message.promote-to-steer" with "provider cannot steer"
      When the user steers the running turn with the queued "update the docs"
      Then the user sees an "error" toast "Failed to steer with the queued message." saying "provider cannot steer"

  Rule: An answer is sent once

    @desktop
    Scenario: An answer waiting on the node is not sent twice
      Given the agent asks to run "npm test"
      And the node holds its answers
      When the user approves it
      Then the approval shows it is being answered
      When the user approves it
      Then the node receives one answer

    @desktop
    Scenario: A failed answer is reported and can be sent again
      Given the agent asks to run "npm test"
      And the node refuses "runtime-request.respond" with "connection closed"
      When the user approves it
      Then the user sees an "error" toast "Failed to submit approval decision." saying "connection closed"
      And the approval is still open so the user can answer again

  Rule: A plan is offered once its turn is over

    @desktop
    Scenario: No plan is offered while the agent is still working
      Given the agent is proposing a plan in the running turn
      Then no plan is offered
