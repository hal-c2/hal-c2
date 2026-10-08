# Sources:
#   apps/desktop-qt/src/native/ComposerController.cpp (the composer's text, send and stop against the MC;
#     unsent sends kept in shell-composer.json and reconciled against the thread's messages after a restart)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   apps/web/src/components/ChatView.tsx (onSend: offline toast, upload, restore on failure,
#     standalone /plan and /default, a draft's first send: title seed, launchThread, the draft kept
#     on failure, background sends and their restore toast)
#   packages/client-runtime/src/commands.ts (the message.dispatch and run.interrupt this mirrors)
#   Shared domain: composer/sending-turns.feature and drafting-and-sending.feature own what a
#   send does; this file owns how the Qt shell keeps the composer's text around its own sends.

Feature: The desktop shell sends a thread's turns to its MC
  The Qt shell keeps each thread's and new thread's composer text, sends turns straight to the
  MC, and clears or restores the text to match.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title | runtimeMode  | interactionMode |
      | t1 | p1      | One   | full-access  | default         |
      | t2 | p1      | Two   | full-access  | default         |
    And the MC has the project "p1" titled "proj-1"
    And the desktop shell is connected to its MC

  Rule: A send clears the composer, and a failed one gives the text back

    @desktop
    Scenario: A send dispatches the message and clears the draft
      Given the composer shows "env-a:t1"
      When the user sends "  Fix the tests  "
      Then the composer's text for "env-a:t1" is ""
      And the MC receives a "message.dispatch" command for "t1"
      And the command's "text" is "Fix the tests"
      And the command's "titleSeed" is "Fix the tests"
      And the command's "dispatchMode.type" is "start_immediately"
      And the MC receives no other commands

    @desktop
    Scenario: A refused send leaves newer typing alone
      Given the MC holds its answers
      And the MC refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1"
      When the user sends "Fix the tests"
      And the user types "Something else" into the composer
      And the MC answers
      Then the composer's text for "env-a:t1" is "Something else"

    @desktop
    Scenario: A refused send keeps the sends queued behind it
      Given the MC holds its answers
      And the MC refuses "message.dispatch" with "Provider unavailable"
      And the composer shows "env-a:t1"
      And the user sends "First"
      When the user sends "Second"
      And the MC answers
      Then the MC receives these messages in order:
        | text  |
        | First |
      And the composer's text for "env-a:t1" is the prompts:
        | prompt |
        | First  |
        | Second |

    @desktop
    Scenario: An image the MC cannot store keeps the draft
      Given the MC refuses "assets.persistChatAttachments" with "Image 'cart.png' could not be saved."
      And the composer shows "env-a:t1"
      And the user attaches the image "cart.png"
      When the user sends "What is wrong here?"
      Then the user sees an "error" toast "Failed to send message" saying "Image 'cart.png' could not be saved."
      And the composer lists the attachment "cart.png"
      And the composer's text for "env-a:t1" is "What is wrong here?"
      And the MC receives no commands

    @desktop
    Scenario: The first message launches the thread and the window moves to it
      Given the composer shows "env-a:t1"
      And the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "  Set up the linter  "
      Then the MC launches the thread with the message "Set up the linter" titled "Set up the linter"
      And the launch is for the draft's thread in "p1"
      And the launch starts in the project folder
      And the window shows the launched thread in the draft's place
      And the sidebar lists no drafts
      When the user goes back
      Then the window shows "env-a:t1"

  Rule: A send cut off by a quit is never lost and never sent twice

    @desktop
    Scenario: A prompt the MC never got comes back as the draft
      Given the MC holds its answers
      And the user is reading "env-a:t1"
      And the user sends "Fix the tests"
      When the desktop quits and starts again
      And the MC drops the send
      And the desktop shell is connected to its MC
      And the user is reading "env-a:t1"
      Then the composer's text for "env-a:t1" is "Fix the tests"
      And the user sees no toast

    @desktop
    Scenario: A prompt the MC got before the quit is not restored
      Given the MC holds its answers
      And the user is reading "env-a:t1"
      And the user sends "Fix the tests"
      And the MC receives a "message.dispatch" command for "t1"
      When the desktop quits and starts again
      And the MC carries out the send
      And the desktop shell is connected to its MC
      And the user is reading "env-a:t1"
      Then the desktop keeps no unsent prompts
      And the composer's text for "env-a:t1" is ""
      And the MC receives no other commands

    @desktop
    Scenario: A cut-off prompt behind newer typing waits behind a toast
      Given the MC holds its answers
      And the user is reading "env-a:t1"
      And the user sends "Fix the tests"
      And the user types "Something else" into the composer
      When the desktop quits and starts again
      And the MC drops the send
      And the desktop shell is connected to its MC
      And the user is reading "env-a:t1"
      Then the user sees an "error" toast "A prompt was not sent" offering "Restore prompt"
      And the composer's text for "env-a:t1" is "Something else"
      When the user types "" into the composer
      And the user chooses "Restore prompt" on the toast "A prompt was not sent"
      Then the composer's text for "env-a:t1" is "Fix the tests"

    @desktop
    Scenario: A cut-off prompt is dropped when the thread has a newer message
      Given the MC holds its answers
      And the user is reading "env-a:t1"
      And the user sends "Fix the tests"
      And the thread "t1" gets the user message "Done it another way" from another device
      When the desktop quits and starts again
      And the MC drops the send
      And the desktop shell is connected to its MC
      And the user is reading "env-a:t1"
      Then the desktop keeps no unsent prompts
      And the composer's text for "env-a:t1" is ""
      And the user sees no toast

    @desktop
    Scenario: A prompt sent while its thread loads is dropped when the thread has a newer message
      Given the MC holds its answers
      And the MC is slow to send threads
      And the composer shows "env-a:t1"
      And the user sends "Fix the tests"
      And the MC sends the thread
      And the thread "t1" gets the user message "Done it another way" from another device
      When the desktop quits and starts again
      And the MC drops the send
      And the desktop shell is connected to its MC
      And the user is reading "env-a:t1"
      Then the desktop keeps no unsent prompts
      And the composer's text for "env-a:t1" is ""
      And the user sees no toast

    @desktop
    Scenario: A new thread's first prompt cut off by a quit comes back to its draft
      Given the MC holds its answers
      And the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the user sends "Set up the linter"
      And the MC launches 1 thread
      When the desktop quits and starts again
      And the MC drops the send
      And the desktop shell is connected to its MC
      Then the composer offers the new thread's text "Set up the linter"
      And the MC launches 1 thread

  Rule: Slash commands the composer knows act, the rest go to the agent

    @desktop
    Scenario: A provider's slash command is sent to the agent
      Given the composer shows "env-a:t1"
      When the user sends "/review"
      Then the MC receives a "message.dispatch" command for "t1"
      And the command's "text" is "/review"

    @desktop
    Scenario: /plan and /default switch the mode without sending
      Given plan mode is turned on
      And the composer shows "env-a:t1"
      When the user sends "/plan"
      Then the composer is in "plan" mode
      And the composer's text for "env-a:t1" is ""
      And the MC receives no commands
      When the user sends "/default"
      Then the composer is in "default" mode
      When the user sends "Build it"
      Then the MC receives these commands in order:
        | type             |
        | message.dispatch |

    @desktop
    Scenario: Without plan mode /plan is sent to the agent
      Given the composer shows "env-a:t1"
      When the user sends "/plan"
      Then the MC receives a "message.dispatch" command for "t1"
      And the command's "text" is "/plan"

    @desktop
    Scenario: A slash command in a new thread starts it
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "/review"
      Then the MC launches 1 thread
      And the window shows the launched thread in the draft's place

    @desktop
    Scenario: A draft the shell does not keep sends nothing
      Given the user opens the draft "draft-1" from the sidebar
      When the user sends "Start"
      Then the MC receives no commands
      And the MC launches no thread

  Rule: A new thread started in the background leaves the window on the draft

    @desktop
    Scenario: A background start offers to open the thread it started
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      When the user sends "Set up the linter" in the background
      Then the MC launches the thread with the message "Set up the linter" titled "Set up the linter"
      And the user sees a "success" toast "Started 1 thread in background" offering "Open"
      And the window shows the draft
      And the composer offers the new thread's text ""
      When the user chooses "Open" on the toast "Started 1 thread in background"
      Then the window shows the thread the background start launched

    @desktop
    Scenario: A background start that fails behind newer typing offers the prompt back
      Given the user sent "Set up the linter" in the background
      And the user types "Something else" into the new thread
      When the background thread fails to start
      Then the user sees an "error" toast "A background prompt could not be sent" offering "Restore prompt"
      And the composer offers the new thread's text "Something else"
      When the user types "" into the new thread
      And the user chooses "Restore prompt" on the toast "A background prompt could not be sent"
      Then the composer offers the new thread's text "Set up the linter"

    @desktop
    Scenario: Sends keep going to the threads the window shows after a background start
      Given the user starts a new thread in "proj-1"
      And the window shows a new draft in "proj-1"
      And the user sends "Set up the linter" in the background
      And the composer shows "env-a:t1"
      When the user sends "First"
      And the composer shows "env-a:t2"
      And the user sends "Second"
      Then the MC receives a "message.dispatch" command for "t1"
      And the MC receives a "message.dispatch" command for "t2"
