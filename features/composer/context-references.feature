# Sources:
#   docs/user/composer.md (slash commands, skills, context references, pull requests, threads, citing)
#   docs/internals/composer-context-references.md
#   apps/server-ex/lib/hal_c2/composer_context.ex (provider envelope, attachment remapping)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (@file, $skill and /command suggestions)
#   apps/desktop-qt/src/native/ComposerController.cpp (terminal excerpts as context records on send)
#   apps/desktop-qt/tests/tst_ComposerKeyboard.qml (suggestion keys)
#   apps/web/src/composer-logic.ts (trigger kinds, built-in slash commands)
#   apps/web/src/components/chat/composerSlashCommandSearch.ts
#   apps/web/src/components/chat/ComposerCommandMenu.tsx
#   apps/web/src/components/chat/ChatComposer.tsx (menu empty states, reference paste failures)
#   apps/web/src/components/ChatView.tsx (/plan, /default, /feedback)
#   packages/contracts/src/settings.ts (showSkillsInSlashMenu)
#   apps/web/src/components/files/FilePreviewPanel.tsx, apps/web/src/reviewCommentContext.ts (file line comments)
#   apps/web/src/components/files/fileTreeDragMention.ts, apps/web/src/components/chat/composerMentionDrag.ts
#   apps/web/src/components/preview/PreviewView.tsx, packages/contracts/src/ipc.ts (preview annotations)
#   apps/web/src/components/contextPresentationRegistry.ts (element and annotation details)
#   apps/web/src/components/ChatView.tsx (/usage-limits panel lifetime, /feedback dispatch)
#   packages/client-runtime/src/state/threadFeedback.ts, apps/web/src/components/chat/ComposerFeedback.tsx

Feature: Referencing files, skills, commands and context
  The user pulls things into a message by typing a trigger character or by
  bringing context from elsewhere in the app. References stay readable in the
  draft and arrive at the provider in a form it understands.

  Background:
    Given a project with an open thread

  @desktop @backlog-desktop
  Scenario Outline: A trigger character offers matching suggestions
    When the user types "<typed>"
    Then the user is offered <suggestions>

    Examples:
      | typed     | suggestions                           |
      | @src/co   | files and folders matching "src/co"   |
      | $rev      | skills matching "rev"                 |
      | /mo       | commands matching "mo"                |

  @desktop @backlog-desktop
  Scenario: Choosing a file suggestion puts the file into the draft
    Given the user has typed "@read"
    When the user chooses "README.md" from the suggestions
    Then the draft references "README.md"

  @desktop @backlog-desktop
  Scenario: Dismissing suggestions does not send the message
    Given the user is offered suggestions
    When the user dismisses them with Escape
    Then no suggestion is inserted
    And nothing has been sent

  @backlog @tui
  Scenario: The terminal client offers file, skill and command suggestions
    When the user types "@src" in the prompt
    Then the user is offered files and folders matching "src"

  @backlog @desktop
  Scenario Outline: Provider commands only apply at the start of a message
    When the user types "<typed>"
    Then <outcome>

    Examples:
      | typed                 | outcome                                    |
      | /compact              | the provider command "compact" is offered  |
      | please /compact       | no provider command is offered             |
      | please /model         | the built-in model command is offered      |

  @backlog @desktop
  Scenario Outline: Choosing a built-in command acts at once and leaves no text behind
    Given the Build and Plan toggle setting is on
    When the user chooses the built-in command "<command>"
    Then <outcome>
    And "<command>" is removed from the draft

    Examples:
      | command  | outcome                                  |
      | /plan    | the thread switches to planning          |
      | /default | the thread switches back to building     |
      | /model   | the user is asked to choose a model      |

  @backlog @desktop
  Scenario: Pull requests are found by number or by title
    Given the project's repository has pull request 42 "Fix login"
    When the user types "#login"
    Then pull request 42 "Fix login" is offered
    When the user chooses it
    Then the draft references pull request 42

  @backlog @desktop
  Scenario: Another thread on the same MC can be referenced
    Given the environment has a thread "Auth refactor"
    When the user references the thread "Auth refactor"
    Then the draft references "Auth refactor"
    And the agent can read that thread's history

  @backlog @desktop
  Scenario: A thread from another environment cannot be referenced
    Given a thread "Remote work" lives in a different environment
    When the user tries to reference it
    Then the user is told the agent can only read threads on its own server
    And the draft is unchanged

  @backlog @desktop
  Scenario: Part of an assistant response can be quoted with a comment
    Given the assistant replied with a paragraph about caching
    When the user cites that paragraph in the composer
    Then the draft carries the quoted paragraph
    And the user can add a comment to it

  @desktop
  Scenario: A terminal excerpt is sent as a reference with its text
    Given the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user sends "Why does this fail?"
    Then the message references the excerpt "Terminal 1 lines 3-5"
    And the message starts with "Why does this fail?"
    And the message carries the excerpt's text
    And the draft no longer holds it

  @desktop
  Scenario: A terminal excerpt can be sent on its own
    Given the user adds line 7 of "Terminal 2" to the chat
    When the user sends ""
    Then the message references the excerpt "Terminal 2 line 7"

  @desktop
  Scenario: A removed terminal excerpt is not sent
    Given the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user removes that excerpt
    And the user sends "Never mind the output"
    Then the message starts with "Never mind the output"
    And the message carries no excerpt

  @desktop
  Scenario: A send the MC rejects gives its terminal excerpt back
    Given the MC refuses "message.dispatch" with "Provider unavailable"
    And the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user sends "Why does this fail?"
    Then the user sees an "error" toast "Failed to send message" saying "Provider unavailable"
    And the composer shows that excerpt with its terminal and lines

  @backlog @desktop
  Scenario: Copied references survive being pasted into another draft
    Given a draft references the terminal excerpt "npm test output"
    When the user copies that text and pastes it into another thread's draft
    Then the other draft references "npm test output" as well

  @backlog @desktop
  Scenario: A pasted reference whose source is unreachable is marked unresolved
    Given the user copied a reference from an environment that is now disconnected
    When the user pastes it into a draft
    Then the reference is marked unresolved
    And the user is told the environment it came from is not connected

  @mc
  Scenario: References reach the provider as labelled markers with their content appended
    Given a message "Look at README" references the file README.md
    When the message is sent to the provider
    Then the provider reads a marker naming the file README in place of the reference
    And the referenced content follows the message in a context envelope

  @mc
  Scenario: Referenced content cannot close the context envelope
    Given a terminal excerpt reference whose label contains "</hal_c2_context>"
    When the message is sent to the provider
    Then that text is escaped so the provider does not read it as the end of the context

  @backlog @desktop
  Scenario: A comment on lines of an open file goes into the draft
    Given the user is reading "src/cart.ts"
    When the user comments "Why is this rounded?" on lines 12 to 14
    Then the draft carries a file comment on "src/cart.ts" lines 12 to 14
    And sending the message gives the provider the comment with those lines of the file

  @backlog @desktop
  Scenario: A file comment follows its lines when the file is edited
    Given the draft carries a comment on line 12 of "src/cart.ts"
    When the user inserts two lines above line 12 in the file
    Then the draft's comment points at line 14 of "src/cart.ts"

  @backlog @desktop
  Scenario: Deleting a comment in the file removes it from the draft
    Given the draft carries a comment on line 12 of "src/cart.ts"
    When the user deletes that comment in the file
    Then the draft no longer carries the comment

  @backlog @desktop
  Scenario: Dragging a file from the file tree references it
    When the user drags "src/app.ts" from the file tree onto the composer
    Then the draft references the file "src/app.ts"
    And "src/app.ts" is not opened or left selected in the tree

  @backlog @desktop
  Scenario: Dragging a selection from the file tree references every selected entry
    Given "src/app.ts" and the folder "src/lib" are selected in the file tree
    When the user drags "src/app.ts" onto the composer
    Then the draft references "src/app.ts" and the folder "src/lib"

  @backlog @desktop
  Scenario Outline: A preview annotation is attached or sent
    Given the user annotated the page "Checkout" in the preview with "Make this button blue"
    When the user chooses to <submission> the annotation
    Then <result>

    Examples:
      | submission | result                                                                              |
      | attach     | the draft carries the annotation with the page, the comment and a picked-area image |
      | send       | a message carrying the annotation is sent right away                                |

  @backlog @desktop
  Scenario: An annotation whose screenshot fails is kept without it
    Given the user annotated a picked element in the preview
    When capturing the element's screenshot fails
    Then the draft carries the annotation without a screenshot
    And the user is told the element could not be captured

  @backlog @desktop
  Scenario: The user opens an annotation from the draft to read it in full
    Given the draft carries an annotation of the page "Checkout"
    When the user opens the annotation
    Then the user sees the page, the comment, the picked elements and the requested style changes

  @backlog @desktop
  Scenario: /usage-limits closes once the agent spends quota again
    Given the user opened "/usage-limits" in a Codex thread
    When the agent resumes after the user answers its approval request
    Then the limits shown above the composer close

  @backlog @desktop
  Scenario: /usage-limits closes when the user switches model
    Given the user opened "/usage-limits" in a Codex thread
    When the user switches the thread to Claude
    Then the limits shown above the composer close

  @backlog @desktop
  Scenario: /usage-limits is left to providers without limits in HAL-C2
    Given a thread on a provider whose limits HAL-C2 does not know
    When the user sends "/usage-limits"
    Then "/usage-limits" is sent to the provider as a message

  @backlog @desktop @tui
  Scenario: /feedback in a Codex thread sends feedback to OpenAI
    Given a Codex thread that has run a turn
    When the user sends "/feedback The agent stopped early"
    Then the draft is cleared and the user sees that feedback is being sent to OpenAI
    And once it is sent the user sees the feedback thread id and can copy it

  @backlog @desktop @tui
  Scenario: /feedback before the first Codex turn is refused
    Given a Codex thread with no messages yet
    When the user sends "/feedback"
    Then the user is told to send a message before submitting feedback

  @backlog @desktop @tui
  Scenario: Feedback that fails to upload says why
    Given a Codex thread that has run a turn
    When the user sends "/feedback" and the upload fails
    Then the user is told the feedback could not be sent to OpenAI and why
    And the user can dismiss the notice

  @backlog @desktop @tui
  Scenario Outline: /feedback is an ordinary message outside a plain Codex draft
    Given <situation>
    When the user sends "/feedback slow"
    Then "/feedback slow" is sent to the agent as a message

    Examples:
      | situation                                  |
      | a Claude thread                            |
      | a Codex draft that carries an image        |
