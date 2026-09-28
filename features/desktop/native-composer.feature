# Sources:
#   apps/desktop-qt/src/native/ComposerController.cpp (the thread's draft, send and stop against the node)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/ChatView.tsx (onSend: offline toast, upload, restore on failure)
#   packages/client-runtime/src/commands.ts (the message.dispatch and run.interrupt this mirrors)
#   Shared domain: composer/ owns what a send does; this file owns that the Qt shell keeps the
#   thread's draft and sends it itself.

Feature: The desktop shell sends a thread's turns to its node
  The Qt shell keeps each thread's draft from the composer's own edits (text, model, modes,
  images) and sends it, or stops the turn, straight to the node. Slash commands and new
  threads still go through the page.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title | runtimeMode  | interactionMode |
      | t1 | p1      | One   | full-access  | default         |
      | t2 | p1      | Two   | full-access  | default         |
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
      Then the user sees an "error" toast "Failed to interrupt the current turn." saying "Run already finished"

  Rule: A send goes to the node

    @desktop
    Scenario: A send dispatches the message and clears the draft
      Given the composer shows "env-a:t1"
      When the user sends "  Fix the tests  "
      Then the page is asked to set the composer text for "env-a:t1" to ""
      And the node receives a "message.dispatch" command for "t1"
      And the command's "text" is "Fix the tests"
      And the command's "titleSeed" is "Fix the tests"
      And the command's "dispatchMode.type" is "start_immediately"
      And the node receives no other commands

    @desktop
    Scenario: The model picked in the composer goes with the message
      Given the composer shows "env-a:t1"
      When the user picks the model "gpt-5" of "codex"
      And the user sends "Fix the tests"
      Then the node receives a "message.dispatch" command for "t1"
      And the command's "modelSelection.model" is "gpt-5"
      And the command's "modelSelection.instanceId" is "codex"

    @desktop
    Scenario: Changed modes are set before the message
      Given the composer shows "env-a:t1"
      When the user switches to the "approval-required" and "plan" modes
      And the user sends "Plan it"
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
      And the composer shows "env-a:t1"
      When the user sends "Fix the tests"
      Then the user sees an "error" toast "Failed to send message" saying "Provider unavailable"
      And the page is asked to set the composer text for "env-a:t1" to "Fix the tests"

    @desktop
    Scenario: A refused send leaves newer typing alone
      Given the node holds its answers
      And the node refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1"
      When the user sends "Fix the tests"
      And the user types "Something else" into the composer
      And the node answers
      Then the page is not asked to set the composer text for "env-a:t1" to "Fix the tests"

    @desktop
    Scenario: A send while the node is out of reach keeps the draft
      Given the composer shows "env-a:t1"
      And the node stops accepting connections
      And the node drops the connection
      When the user sends "Fix the tests"
      Then the user sees a "warning" toast "Not connected: message not sent" saying "Reconnecting to the environment. Try again once it is connected."
      And the node receives no commands
      And the page is not asked to set the composer text for "env-a:t1" to ""

    @desktop
    Scenario: A second send on a thread goes out after the first
      Given the node holds its answers
      And the composer shows "env-a:t1"
      And the user sends "First"
      When the user sends "Second"
      And the node answers
      Then the node receives these messages in order:
        | text   |
        | First  |
        | Second |

    @desktop
    Scenario: A refused send keeps the sends queued behind it
      Given the node holds its answers
      And the node refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1"
      And the user sends "First"
      When the user sends "Second"
      And the node answers
      Then the node receives these messages in order:
        | text  |
        | First |
      And the page is asked to set the composer text for "env-a:t1" to the prompts:
        | prompt |
        | First  |
        | Second |

    @desktop
    Scenario: A send on one thread does not wait for another thread's send
      Given the node holds its answers
      And the composer shows "env-a:t1"
      When the user sends "First"
      And the composer shows "env-a:t2"
      And the user sends "Second"
      Then the node receives a "message.dispatch" command for "t1"
      And the node receives a "message.dispatch" command for "t2"

  Rule: Each thread keeps its own draft

    @desktop
    Scenario: A thread's draft is offered again when the user comes back to it
      Given the composer shows "env-a:t1"
      And the user types "half a thought" into the composer
      When the user opens "env-a:t2" from the sidebar
      Then the composer offers the draft ""
      When the user opens "env-a:t1" from the sidebar
      Then the composer offers the draft "half a thought"

  Rule: Images go up before the message that carries them

    @desktop
    Scenario: An attached image is stored by the node and sent with the message
      Given the composer shows "env-a:t1"
      When the user attaches the image "cart.png"
      Then the composer lists the attachment "cart.png"
      When the user sends "What is wrong here?"
      Then the node stores the image "cart.png" for "t1"
      And the node receives a "message.dispatch" command for "t1"
      And the message carries the image "cart.png"
      And the composer lists no attachments

    @desktop
    Scenario: An image alone can be sent
      Given the composer shows "env-a:t1"
      And the user attaches the image "cart.png"
      When the user sends ""
      Then the node receives a "message.dispatch" command for "t1"
      And the message carries the image "cart.png"

    @desktop
    Scenario: A removed image is not sent
      Given the composer shows "env-a:t1"
      And the user attaches the image "cart.png"
      When the user removes the attachment "cart.png"
      Then the composer lists no attachments
      When the user sends "Never mind the picture"
      Then the node receives a "message.dispatch" command for "t1"
      And the node stores no images

    @desktop
    Scenario: An image the node cannot store keeps the draft
      Given the node refuses "assets.persistChatAttachments" with "Image 'cart.png' could not be saved."
      And the composer shows "env-a:t1"
      And the user attaches the image "cart.png"
      When the user sends "What is wrong here?"
      Then the user sees an "error" toast "Failed to send message" saying "Image 'cart.png' could not be saved."
      And the composer lists the attachment "cart.png"
      And the page is asked to set the composer text for "env-a:t1" to "What is wrong here?"
      And the node receives no commands

  Rule: Slash commands and new threads stay with the page

    @desktop
    Scenario: A slash command goes to the page
      Given the composer shows "env-a:t1"
      When the user sends "/review"
      Then the action "composer.submit" reaches the page
      And the node receives no commands

    @desktop
    Scenario: A draft thread goes to the page
      Given the composer shows the draft "draft-1"
      When the user sends "Start"
      Then the action "composer.submit" reaches the page
      And the node receives no commands
      When the desktop quits and starts again
      And the page's own link takes it to "env-a:t1"
      And the desktop shell is connected to its node
      Then the window shows "env-a:t1"
      And the page is not told where to go
