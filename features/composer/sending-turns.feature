# Sources:
#   apps/desktop-qt/src/native/ComposerController.cpp (the thread's draft, send, stop, images and a
#     new thread's launch against the node)
#   apps/desktop-qt/tests/native/features/ComposerSteps.cpp, LaunchSteps.cpp
#   apps/web/src/components/ChatView.tsx (onSend: upload, a draft's first send: title seed, launchThread)
#   packages/client-runtime/src/commands.ts (message.dispatch, run.interrupt)
#   Shared domain: drafting-and-sending.feature owns sending from the composer in general;
#   desktop/native-composer.feature owns how the Qt shell's sends meet the page's composer.

Feature: Sending a thread's turns to its node
  A send carries what the user picked in the composer, goes out in order, and never waits on
  another thread. Stop interrupts whatever the thread is running. Images go up before the
  message that carries them. A new thread's first message launches the thread, once.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title | runtimeMode  | interactionMode |
      | t1 | p1      | One   | full-access  | default         |
      | t2 | p1      | Two   | full-access  | default         |
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node

  Rule: Stop interrupts the thread's run

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

    @desktop
    Scenario: A refused stop shows why in a toast
      Given the node updates the thread "t1" with:
        | activeRunId | run-2 |
      And the node refuses "run.interrupt" with "Run already finished"
      And the composer shows "env-a:t1"
      When the user stops the turn
      Then the user sees an "error" toast "Failed to interrupt the current turn." saying "Run already finished"

    @desktop
    Scenario: Stop interrupts the thread the window shows
      Given the node updates the thread "t2" with:
        | activeRunId | run-2 |
      And the composer shows "env-a:t1"
      When the user opens "env-a:t2" from the sidebar
      And the user stops the turn
      Then the node receives a "run.interrupt" command for "t2"

  Rule: A send goes to the node

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
    Scenario: A send on one thread does not wait for another thread's send
      Given the node holds its answers
      And the composer shows "env-a:t1"
      When the user sends "First"
      And the composer shows "env-a:t2"
      And the user sends "Second"
      Then the node receives a "message.dispatch" command for "t1"
      And the node receives a "message.dispatch" command for "t2"

    @desktop
    Scenario: A send goes to the thread the window shows
      Given the composer shows "env-a:t1"
      When the user opens "env-a:t2" from the sidebar
      And the user sends "hello"
      Then the node receives a "message.dispatch" command for "t2"
      And the node receives no other commands

  Rule: Each thread keeps its own draft

    @desktop
    Scenario: A new thread's text is kept with its draft
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the user types "set up the linter" into the new thread
      When the user opens "env-a:t1" from the sidebar
      And the user goes back to the new thread
      Then the composer offers the new thread's text "set up the linter"

    @desktop
    Scenario: A new thread's text is still there after a restart
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the user types "set up the linter" into the new thread
      When the desktop quits and starts again
      And the desktop shell is connected to its node
      Then the composer offers the new thread's text "set up the linter"

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

  Rule: A new thread's first message launches its thread

    @desktop
    Scenario: A long first message is cut down for the title
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "Set up the linter and fix every warning it reports in the cart"
      Then the node launches the thread with the message "Set up the linter and fix every warning it reports in the cart" titled "Set up the linter and fix every warning it reports..."

    @desktop
    Scenario: The model and modes picked for the new thread go with its launch
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user picks the model "gpt-5" of "codex"
      And the user switches to the "approval-required" and "plan" modes
      And the user sends "Plan it"
      Then the launch uses the model "gpt-5" of "codex" in the "approval-required" and "plan" modes

    @desktop
    Scenario: An image goes up before the new thread is launched with it
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the user attaches the image "cart.png"
      Then the composer lists the attachment "cart.png"
      When the user sends ""
      Then the node stores the image "cart.png" for the draft's thread
      And the node launches the thread with the message "" titled "Image: cart.png"
      And the launch carries the image "cart.png"

    @desktop
    Scenario: A launch the node refuses keeps the draft and says why
      Given the node refuses "orchestration.launchThread" with "Provider unavailable"
      And the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the user attaches the image "cart.png"
      When the user sends "Set up the linter"
      Then the user sees an "error" toast "Could not create thread" saying "Provider unavailable"
      And the window shows the draft
      And the new thread still reads "Set up the linter"
      And the composer lists the attachment "cart.png"
      And the sidebar lists the draft

    @desktop
    Scenario: A new thread is launched once however often the user sends
      Given the node holds its answers
      And the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "Set up the linter"
      And the user sends "Set up the linter"
      And the node answers
      Then the node launches 1 thread
      And the window shows the launched thread in the draft's place

    @desktop
    Scenario: A new thread is not launched while the node is out of reach
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the node stops accepting connections
      And the node drops the connection
      When the user sends "Set up the linter"
      Then the user sees a "warning" toast "Not connected: message not sent" saying "Reconnecting to the environment. Try again once it is connected."
      And the node launches no thread
      And the window shows the draft
      And the new thread still reads "Set up the linter"

    @desktop
    Scenario: An empty first message launches nothing
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "   "
      Then the node launches no thread
      And the window shows the draft
