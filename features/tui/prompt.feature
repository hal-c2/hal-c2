# Sources:
#   apps/tui/src/components/ChatComposer.tsx, ChatComposer.test.tsx
#   apps/tui/src/components/ComposerFooter.tsx (primary action)
#   apps/tui/src/components/ChatView.tsx (send acknowledgement, image paste, attachment limits)
#   apps/tui/src/promptEditor.ts, promptEditor.test.ts ($EDITOR)
#   apps/tui/src/composerAttachments.ts, composerAttachments.test.ts
#   packages/opentui-image (Kitty OSC 5522 clipboard paste)
#   apps/tui/src/features.backlog.test.ts (composer-command-discovery, composer-context-chips)
#   Shared domain: composer/ owns drafting and sending on every surface.

Feature: Writing a prompt in the terminal
  The prompt is a multi-line editor that sends on Enter, hands off to the user's own editor,
  and turns pasted images and image paths into attachments.

  Background:
    Given the terminal client is open on a thread with focus in the prompt

  @tui
  Scenario: Enter sends the reply
    Given the prompt contains "Run the tests"
    When the user presses "Enter"
    Then "Run the tests" is sent to the thread

  @tui
  Scenario: Shift+Enter adds a new line instead of sending
    Given the prompt contains "First line"
    When the user presses "Shift+Enter" and types "Second line"
    Then the prompt holds two lines and nothing is sent

  @tui
  Scenario: A multi-line paste is inserted whole without sending
    When the user pastes ten lines of text
    Then all ten lines are in the prompt
    And nothing is sent

  @tui
  Scenario: A reply is sent once even when Enter repeats
    Given a reply is being sent
    When the user presses "Enter" again before the server answers
    Then only one reply is sent

  @tui
  Scenario: The draft clears only when the server accepts the reply
    Given the prompt contains "Run the tests"
    When the user sends it and the server accepts it
    Then the prompt is empty

  @tui
  Scenario: A failed send keeps the exact draft
    Given the prompt contains "Run the tests"
    When the user sends it and the request fails
    Then the prompt still contains "Run the tests"

  @tui
  Scenario: Global chords never eat the draft
    Given the prompt contains "half written"
    When the user presses "Ctrl+K" and then closes the palette
    Then the prompt still contains "half written"

  @tui
  Scenario: Esc clears the draft
    Given the prompt contains "never mind"
    When the user presses "Esc"
    Then the prompt is empty

  @tui
  Scenario: Esc with an empty prompt stops the running turn
    Given the prompt is empty
    And the thread is running a turn
    When the user presses "Esc"
    Then the turn is interrupted

  @tui
  Scenario: The primary action follows the thread's state
    Then the primary action is "Send" when the thread is idle
    And it is "Stop" while the agent is working
    And it is "Submit answer" while a question is pending

  @tui
  Scenario: The prompt opens in the user's editor
    Given the environment variable "VISUAL" is "code --wait"
    When the user presses "Ctrl+G"
    Then the draft opens in "code --wait"
    And the edited text replaces the draft when the editor closes

  @tui
  Scenario Outline: The editor command falls back in a fixed order
    Given VISUAL is <visual> and EDITOR is <editor>
    When the user presses "Ctrl+G"
    Then the draft opens in <command>

    Examples:
      | visual  | editor | command |
      | "hx"    | "nano" | "hx"    |
      | unset   | "nano" | "nano"  |
      | unset   | unset  | "vi"    |
      | blank   | blank  | "vi"    |

  @tui
  Scenario: Text from the editor comes back tidy
    When the user saves a draft with Windows line endings and trailing blank lines in the editor
    Then the prompt uses plain line endings
    And the trailing blank lines are gone while interior blank lines stay

  @tui
  Scenario: Image paths written in the editor become attachments
    When the user saves a draft in the editor with a line that is only a workspace image path
    Then that image is attached
    And the path line is removed from the prompt

  @tui
  Scenario: Pasting image bytes attaches the image
    Given the clipboard holds a PNG image
    When the user pastes into the prompt
    Then the image is attached
    And the draft text is unchanged

  @tui
  Scenario: Pasting a workspace image path attaches the image
    When the user pastes "assets/logo.png"
    Then the image is attached
    And the path is not inserted into the prompt

  @tui
  Scenario: Pasting a local image outside the workspace attaches it
    When the user pastes "~/Pictures/bug.png"
    Then the image is attached from the local disk

  @tui
  Scenario: Pasting prose with an image path keeps the prose
    When the user pastes "Why does ~/Pictures/bug.png look wrong?"
    Then the image is attached
    And the prompt holds the prose without the path

  @tui
  Scenario: An image path that cannot be read stays as text
    When the user pastes "assets/missing.png"
    Then the prompt contains "assets/missing.png"
    And nothing is attached

  @tui
  Scenario: A malformed image paste is refused
    Given the clipboard holds truncated image bytes
    When the user pastes into the prompt
    Then nothing is attached
    And the status line says "Paste a supported image format."

  @tui
  Scenario: The same image cannot be attached twice
    Given "logo.png" is attached
    When the user attaches "logo.png" again
    Then the status line says "logo.png" is already attached

  @tui
  Scenario: The number of attachments is capped
    Given the prompt has the most attachments a turn allows
    When the user attaches another image
    Then the image is refused
    And the status line says how many images a turn can carry

  @tui
  Scenario: The user removes an attachment before sending
    Given "logo.png" is attached
    When the user removes the last attachment
    Then "logo.png" is no longer attached

  @tui
  Scenario: Attached images are sent with the reply
    Given "logo.png" is attached and the prompt contains "Match this"
    When the user sends the reply
    Then the reply carries "Match this" and a bounded copy of "logo.png"

  @backlog @tui
  Scenario: The user recalls earlier prompts
    Given the user sent "Run the tests" earlier in this thread
    When the user asks for the previous prompt in an empty prompt
    Then the prompt contains "Run the tests"

  @backlog @tui
  Scenario Outline: The user discovers context with a trigger character
    When the user types "<trigger>" in the prompt
    Then a list of <items> opens to pick from

    Examples:
      | trigger | items          |
      | /       | slash commands |
      | $       | skills         |
      | @       | files          |

  @backlog @tui
  Scenario: Context references show as removable chips
    Given the user added a file reference to the prompt
    Then the reference shows as a chip
    And the user can remove it before sending

  @backlog @tui
  Scenario: Sent context references stay readable in the timeline
    When the user sends a prompt with a file reference
    Then the sent message shows the reference inline
