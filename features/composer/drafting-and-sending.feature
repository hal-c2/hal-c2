# Sources:
#   docs/user/composer.md (message limits, sending, background prompts, multiple models)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (text sync, submit, draft target)
#   apps/desktop-qt/tests/tst_Composer.qml
#   apps/desktop-qt/src/native/ComposerController.cpp (isSendBusy while a message is on its way)
#   apps/desktop-qt/qml/HalC2/Bricks/Timeline.qml (Sending…)
#   apps/desktop-qt/tests/tst_ComposerKeyboard.qml
#   apps/tui/src/components/ChatView.tsx (reply draft, send status, new thread composer)
#   apps/web/src/composer-logic.ts (submission intents, send shortcut)
#   apps/web/src/composerDraftStore.ts (per-thread drafts)
#   apps/web/src/components/chat/composerSubmission.ts (length validation)
#   apps/web/src/components/ChatView.tsx (send path, offline, background send, multi-model)
#   packages/contracts/src/settings.ts (sendShortcut)

Feature: Drafting and sending a message
  The user writes a turn and sends it to the agent. Drafts survive switching
  away, sending never loses text, and a message that cannot be sent says why.

  Background:
    Given a project with an open thread
    And the thread's provider is ready

  @desktop @tui
  Scenario: Enter sends the message
    Given the user has typed "Fix the failing test"
    When the user presses Enter
    Then the message "Fix the failing test" is sent to the agent
    And the composer is empty

  @desktop
  Scenario: Shift+Enter starts a new line instead of sending
    Given the user has typed "first line"
    When the user presses Shift+Enter and types "second line"
    Then the draft holds two lines
    And nothing has been sent

  @desktop
  Scenario Outline: The send shortcut setting decides what Enter does
    Given the send shortcut setting is "<setting>"
    And the user has typed <draft>
    When the user presses <keys>
    Then <outcome>

    Examples:
      | setting                          | draft               | keys      | outcome                          |
      | Enter                            | "hello"             | Enter     | the message is sent              |
      | Mod+Enter for multiline prompts  | "hello"             | Enter     | the message is sent              |
      | Mod+Enter for multiline prompts  | two lines           | Enter     | a new line is added to the draft |
      | Mod+Enter for multiline prompts  | two lines           | Mod+Enter | the message is sent              |
      | Mod+Enter                        | "hello"             | Enter     | a new line is added to the draft |
      | Mod+Enter                        | "hello"             | Mod+Enter | the message is sent              |

  @backlog @mobile
  Scenario: A hardware keyboard on the phone follows the send shortcut setting
    Given the send shortcut setting is "Mod+Enter"
    And the user has typed "hello" on a hardware keyboard
    When the user presses Enter
    Then a new line is added to the draft

  @desktop
  Scenario: mod+alt+Enter starts a new thread in the background
    Given the user is writing the first message of a new thread
    When the user presses mod+alt+Enter
    Then a new thread starts with that message in the background
    And no window shortcut takes the key instead

  @desktop @backlog-desktop
  Scenario: The draft stays until the send is confirmed
    Given the user has typed "keep me"
    When the user sends the message
    Then the draft still reads "keep me" until the thread confirms the send
    And the draft clears once the send is confirmed

  @desktop
  Scenario: Switching threads before the draft syncs does not leak text into the new thread
    Given the user has just typed "for thread A" in thread A
    When the user switches to thread B before the draft is saved
    Then thread B's draft does not contain "for thread A"

  @desktop @tui @mobile @backlog-mobile
  Scenario: Each thread keeps its own draft
    Given the user has typed "draft for A" in thread A
    When the user switches to thread B and back to thread A
    Then thread A's draft reads "draft for A"
    And thread B's draft is empty

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: The thread says a message is sending until its MC takes it
    Given the user has typed "Fix the failing test"
    When the user sends it before the MC answers
    Then the thread says the message is sending
    When the MC takes the message
    Then the thread no longer says the message is sending

  @desktop
  Scenario: A new thread's first message leaves the composer as it is sent
    Given the user starts a new thread in the project
    And the user has typed "Fix the failing test"
    When the user sends it before the MC answers
    Then the composer is empty
    And the thread says the message is sending
    When the MC takes the message
    Then the thread no longer says the message is sending

  @tui
  Scenario: Text typed while a message is sending is kept
    Given the user has sent "first"
    And the reply is still sending
    When the user types "second"
    Then the draft reads "second" after the send completes

  @desktop @mobile @backlog-mobile
  Scenario: A message over the character limit is refused before sending
    Given the user has typed a prompt 10 characters over the 120,000-character limit
    When the user tries to send it
    Then the message is not sent
    And the user is told the prompt is 10 characters over the limit and to shorten or split it

  @desktop @tui @mobile @backlog-mobile
  Scenario: Sending while disconnected keeps the draft
    Given the environment is disconnected
    And the user has typed "are you there"
    When the user tries to send it
    Then the user is told the message was not sent because they are not connected
    And the draft still reads "are you there"

  @desktop @tui @mobile @backlog-mobile
  Scenario: A send the MC rejects restores the draft
    Given the user has typed "do the thing"
    When the user sends it and the MC rejects the message
    Then the user sees why the send failed
    And the draft reads "do the thing" again

  @desktop @tui
  Scenario: The first message of a new thread creates the thread and starts its turn
    Given the user is starting a new thread in the project
    When the user sends "Set up the linter"
    Then a thread titled from "Set up the linter" is created
    And its first turn starts with that message

  @desktop
  Scenario: A background prompt starts a thread without leaving the composer
    Given the user is writing the first message of a new thread
    When the user sends it in the background
    Then a new thread starts with that message
    And the user is told it started in the background with a way to open it
    And the composer is ready for another prompt

  @desktop
  Scenario: A background prompt that fails can be restored
    Given the user sent "refactor utils" in the background
    When the background thread fails to start
    Then the user is told the background prompt could not be sent
    And the user can restore "refactor utils" into the composer

  @desktop
  Scenario: One prompt starts a thread for each chosen model
    Given the project is a Git repository
    And the user is starting a new thread
    When the user chooses two models and a base branch and sends "Add caching"
    Then one thread per model starts with "Add caching"
    And each thread works in its own worktree
