# Sources:
#   apps/desktop-qt/src/native/ComposerController.cpp (the thread's draft, send and stop against the node)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/ChatView.tsx (onSend: offline toast, upload, restore on failure,
#     a draft's first send: title seed, launchThread, the draft kept on failure)
#   packages/client-runtime/src/commands.ts (the message.dispatch and run.interrupt this mirrors)
#   Shared domain: composer/sending-turns.feature and drafting-and-sending.feature own what a
#   send does; this file owns how the Qt shell's own sends meet the page's composer text, and
#   what still goes through the page.

Feature: The desktop shell sends a thread's turns to its node
  The Qt shell sends a thread's turns straight to the node, and clears or restores the text in
  the page's composer to match. Slash commands, background starts and drafts only the page
  has still go through the page.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title | runtimeMode  | interactionMode |
      | t1 | p1      | One   | full-access  | default         |
      | t2 | p1      | Two   | full-access  | default         |
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node

  Rule: The shell's sends set the page's composer text

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
    Scenario: A refused send leaves newer typing alone
      Given the node holds its answers
      And the node refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1"
      When the user sends "Fix the tests"
      And the user types "Something else" into the composer
      And the node answers
      Then the page is not asked to set the composer text for "env-a:t1" to "Fix the tests"

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
    Scenario: An image the node cannot store keeps the draft
      Given the node refuses "assets.persistChatAttachments" with "Image 'cart.png' could not be saved."
      And the composer shows "env-a:t1"
      And the user attaches the image "cart.png"
      When the user sends "What is wrong here?"
      Then the user sees an "error" toast "Failed to send message" saying "Image 'cart.png' could not be saved."
      And the composer lists the attachment "cart.png"
      And the page is asked to set the composer text for "env-a:t1" to "What is wrong here?"
      And the node receives no commands

    @desktop
    Scenario: The first message launches the thread and the window moves to it
      Given the composer shows "env-a:t1"
      And the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "  Set up the linter  "
      Then the node launches the thread with the message "Set up the linter" titled "Set up the linter"
      And the launch is for the draft's thread in "p1"
      And the launch starts in the project folder
      And the window shows the launched thread in the draft's place
      And the page is asked to set the composer text for the draft to ""
      And the sidebar lists no drafts
      When the user goes back
      Then the window shows "env-a:t1"

  Rule: Slash commands, background starts and drafts only the page has stay with the page

    @desktop
    Scenario: A slash command goes to the page
      Given the composer shows "env-a:t1"
      When the user sends "/review"
      Then the action "composer.submit" reaches the page
      And the node receives no commands

    @desktop
    Scenario: A draft only the page has goes to the page
      Given the composer shows the draft "draft-1"
      When the user sends "Start"
      Then the action "composer.submit" reaches the page
      And the node receives no commands
      When the desktop quits and starts again
      And the page's own link takes it to "env-a:t1"
      And the desktop shell is connected to its node
      Then the window shows "env-a:t1"
      And the page is not told where to go

    @desktop
    Scenario: A slash command in a new thread goes to the page
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "/review"
      Then the action "composer.submit" reaches the page
      And the node launches no thread

    @desktop
    Scenario: A new thread started in the background goes to the page
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "Set up the linter" in the background
      Then the action "composer.submit" reaches the page
      And the node launches no thread
