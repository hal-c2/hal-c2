# Sources:
#   docs/user/composer.md (prompt recall, prompt stash)
#   docs/internals/composer-editors.md
#   apps/desktop-qt/qml/HalC2/Bricks/ComposerVimKeys.qml
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (editor actions, text insertion)
#   apps/desktop-qt/tests/tst_ComposerExtensions.qml
#   apps/desktop-qt/tests/tst_ComposerActions.qml
#   apps/tui/src/promptEditor.ts
#   apps/tui/src/components/ChatView.tsx (external editor, prompt height)
#   apps/web/src/composerPromptHistory.ts
#   apps/web/src/components/chat/ComposerStashMenu.tsx
#   apps/web/src/components/chat/ChatComposer.tsx (stash toasts)
#   packages/shared/src/keybindings.ts (composer.stash)
#   packages/contracts/src/settings.ts (composerRichTextEnabled, fontFamilyComposer)

Feature: Editing the draft
  The user edits the draft with the keys they are used to, in an outside
  editor, or by recalling and stashing earlier prompts.

  Background:
    Given a project with an open thread

  @desktop
  Scenario: Escape enters normal mode when Vim keys are on
    Given Vim keys are on
    And the user has typed "hello world"
    When the user presses Escape
    Then typed letters move the cursor instead of inserting text

  @desktop
  Scenario Outline: Normal mode keys edit and move like Vim
    Given Vim keys are on and the editor is in normal mode
    And the draft reads "hello world" with the cursor at the start
    When the user presses <keys>
    Then <outcome>

    Examples:
      | keys | outcome                                  |
      | w    | the cursor moves to "world"              |
      | $    | the cursor moves to the end of the line  |
      | x    | the draft reads "ello world"             |
      | A    | the user inserts at the end of the line  |

  @desktop
  Scenario: Enter in normal mode does not send
    Given Vim keys are on and the editor is in normal mode
    When the user presses Enter
    Then nothing has been sent

  @desktop
  Scenario: Switching threads returns Vim keys to insert mode
    Given Vim keys are on and the editor is in normal mode
    When the user switches to another thread
    Then typed letters insert text

  @backlog @desktop
  Scenario: Vim keys can be turned on from settings
    When the user turns on Vim keys in settings
    Then the composer edits with Vim keys

  @desktop
  Scenario: Inserted text replaces the selection without sending
    Given the draft reads "hello world" with "world" selected
    When text "there" is inserted into the composer
    Then the draft reads "hello there"
    And nothing has been sent

  @desktop
  Scenario: Text meant for another thread is not inserted
    Given the user is writing in thread B
    When text meant for thread A arrives late
    Then thread B's draft is unchanged

  @tui
  Scenario: The draft can be written in the user's own editor
    Given the user's editor is set in VISUAL or EDITOR
    And the draft reads "start"
    When the user opens the draft in their editor and saves "start\nmore"
    Then the draft reads the saved text without trailing blank lines

  @tui
  Scenario: An image path written in the outside editor becomes an attachment
    When the user saves a line naming "./bug.png" from their editor
    Then "bug.png" is attached
    And that line is not part of the prompt text

  @backlog @desktop @mobile
  Scenario: Earlier prompts are recalled in an empty composer
    Given the user sent "first" and then "second" in this thread
    And the composer is empty
    When the user recalls the previous prompt twice
    Then the draft reads "first"
    When the user moves forward again
    Then the draft reads "second"

  @backlog @desktop
  Scenario: Stashing a prompt clears the composer and it can be restored
    Given the draft reads "half-finished idea"
    When the user stashes the prompt
    Then the composer is empty
    When the user restores the stashed prompt
    Then the draft reads "half-finished idea"

  @backlog @desktop
  Scenario: A prompt cannot be stashed while its files are uploading
    Given the draft carries a file that is still uploading
    When the user stashes the prompt
    Then the user is asked to wait for file uploads before stashing
    And the draft is unchanged

  @backlog @desktop
  Scenario: Turning rich text off keeps the draft as plain Markdown
    Given rich text editing is on and the draft shows "bold" in bold
    When the user turns rich text editing off
    Then the draft reads "**bold**"
