# Sources:
#   apps/desktop-qt/src/ComposerController.cpp (interrupt and plain send against the node)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/shell/ShellComposerBridge.tsx (publishes composer.nativeSend)
#   packages/client-runtime/src/commands.ts (the message.dispatch and run.interrupt this mirrors)
#   Shared domain: composer/ owns what a send does; this file owns that the Qt shell sends a
#   plain one itself.

Feature: The desktop shell sends plain turns to its node
  Stopping a turn and sending a plain message (text only, one model, nothing attached) go from
  the Qt shell straight to the node. The page marks which prompt is plain; anything richer, or
  a prompt typed after the page last looked, still goes through the page.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title | runtimeMode  | interactionMode |
      | t1 | p1      | One   | full-access  | default         |
    And the page groups "env-a:p1" as the project "proj-1"
    And the desktop shell is connected to its node

  Rule: Stop interrupts the thread's run

    @desktop
    Scenario: Stop interrupts the active run
      Given the node updates the thread "t1" with:
        | activeRunId | run-2 |
        | latestRunId | run-2 |
        | status      | running |
      And the composer shows "env-a:t1"
      When the user stops the turn
      Then the node receives a "run.interrupt" command for "t1"
      And the command's "runId" is "run-2"
      And nothing reaches the page

    @desktop
    Scenario: Stop interrupts a run still waiting on background work
      Given the node updates the thread "t1" with:
        | latestRunId            | run-1 |
        | pendingBackgroundTasks | 1     |
      And the composer shows "env-a:t1"
      When the user stops the turn
      Then the node receives a "run.interrupt" command for "t1"
      And the command's "runId" is "run-1"

    @desktop
    Scenario: Stop with nothing running does nothing
      Given the composer shows "env-a:t1"
      When the user stops the turn
      Then the node receives no commands
      And nothing reaches the page

    @desktop
    Scenario: A refused stop shows why in a toast
      Given the node updates the thread "t1" with:
        | activeRunId | run-2 |
      And the node refuses "run.interrupt" with "Run already finished"
      And the composer shows "env-a:t1"
      When the user stops the turn
      Then the page shows an "error" toast "Failed to interrupt the current turn." saying "Run already finished"

  Rule: A plain send goes to the node

    @desktop
    Scenario: A plain send dispatches the message and clears the draft
      Given the composer shows "env-a:t1" with the plain prompt "  Fix the tests  "
      When the user sends "  Fix the tests  "
      Then the page is asked to set the composer text for "env-a:t1" to ""
      And the node receives a "message.dispatch" command for "t1"
      And the command's "text" is "Fix the tests"
      And the command's "titleSeed" is "Fix the tests"
      And the command's "modelSelection.model" is "gpt-5"
      And the command's "dispatchMode.type" is "start_immediately"
      And the node receives no other commands

    @desktop
    Scenario: Changed modes are set before the message
      Given the composer shows "env-a:t1" with the plain prompt "Plan it" in "approval-required" and "plan" modes
      When the user sends "Plan it"
      Then the node receives these commands in order:
        | type                        |
        | thread.runtime-mode.set     |
        | thread.interaction-mode.set |
        | message.dispatch            |
      And the command "thread.runtime-mode.set" has "runtimeMode" "approval-required"
      And the command "thread.interaction-mode.set" has "interactionMode" "plan"

    @desktop
    Scenario: A refused send restores the draft and says why
      Given the node refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1" with the plain prompt "Fix the tests"
      When the user sends "Fix the tests"
      Then the page shows an "error" toast "Failed to send message" saying "Provider unavailable"
      And the page is asked to set the composer text for "env-a:t1" to "Fix the tests"

    @desktop
    Scenario: A refused send leaves newer typing alone
      Given the node holds its answers
      And the node refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1" with the plain prompt "Fix the tests"
      When the user sends "Fix the tests"
      And the user types "Something else" into the composer
      And the node answers
      Then the page is not asked to set the composer text for "env-a:t1" to "Fix the tests"

  Rule: Anything the page has not vouched for stays with the page

    @desktop
    Scenario: A prompt typed after the page last looked goes to the page
      Given the composer shows "env-a:t1" with the plain prompt "Fix the"
      When the user sends "Fix the tests"
      Then the action "composer.submit" reaches the page
      And the node receives no commands

    @desktop
    Scenario: A prompt the page does not mark plain goes to the page
      Given the composer shows "env-a:t1"
      When the user sends "/review"
      Then the action "composer.submit" reaches the page
      And the node receives no commands

    @desktop
    Scenario: A draft thread goes to the page
      Given the composer shows the draft "draft-1" with the plain prompt "Start"
      When the user sends "Start"
      Then the action "composer.submit" reaches the page
      And the node receives no commands
