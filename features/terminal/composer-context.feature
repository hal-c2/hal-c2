# Sources:
#   docs/user/composer.md (terminal excerpts as context chips)
#   apps/web/src/lib/terminalContext.ts (normalizeTerminalContextSelection, formatTerminalContextLabel, expired contexts)
#   apps/web/src/components/ThreadTerminalDrawer.tsx (terminalSelectionMenuItems, terminalContextMenuItems)
#   apps/web/src/composerDraftStore.ts (terminalContexts on drafts, legacy placeholder migration)
#   apps/web/src/components/ChatView.tsx, ChatView.logic.ts (buildExpiredTerminalContextToastCopy: expired excerpts at send)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (terminal selection chips, composer.terminalContext.remove)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalSplits.qml (the terminal menu's Add to chat)
#   apps/desktop-qt/src/native/ComposerController.cpp (addTerminalContext, withTerminalContexts)
#   apps/tui/src/features.backlog.test.ts (terminal-session-actions, composer context chips)
#   Cross-domain: composer/context-references.feature owns how chips sit inside the prompt and
#   reach the provider; this file owns getting terminal output into the draft.

Feature: Adding terminal output to a message
  The user can hand the agent a piece of terminal output. The excerpt travels with the draft
  and names the terminal and lines it came from.

  @desktop
  Scenario: The user adds selected terminal output to the draft
    Given "Terminal 1" shows a failing test on lines 3 to 5
    When the user selects those lines and adds them to the chat
    Then the draft gains an excerpt labelled "Terminal 1 lines 3-5"
    And the excerpt holds the selected text

  @desktop
  Scenario: A one-line selection names a single line
    When the user adds line 7 of "Terminal 2" to the chat
    Then the draft gains an excerpt labelled "Terminal 2 line 7"

  @desktop
  Scenario: Selecting only blank lines adds nothing
    When the user selects blank lines in the terminal and adds them to the chat
    Then the draft gains no excerpt

  @desktop
  Scenario: Adding to chat is not offered where there is no draft to add to
    Given the terminal is shown somewhere without a message draft
    When the user selects terminal output
    Then the user is offered to copy it but not to add it to the chat

  @desktop
  Scenario: The terminal's menu offers selection actions only once something is selected
    Given nothing is selected in the terminal
    When the user opens the terminal's menu
    Then adding to chat and copying are unavailable
    And pasting is available

  @desktop
  Scenario: The draft lists its terminal excerpts
    Given the draft holds an excerpt from "Terminal 1" lines 3 to 5
    Then the composer shows that excerpt with its terminal and lines

  @desktop
  Scenario: The user removes a terminal excerpt from the draft
    Given the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user removes that excerpt
    Then the draft no longer holds it
    And the rest of the draft is unchanged

  @desktop
  Scenario: An excerpt whose text is gone is dropped when the message is sent
    Given a restored draft holds a terminal excerpt with no text left
    When the user sends the message
    Then the empty excerpt is not sent

  @backlog @desktop
  Scenario Outline: The user is told when expired terminal excerpts are left out of a message
    Given the draft reads "Why did this fail?" and holds <count> whose text is gone
    When the user sends the message
    Then the message is sent without them
    And the user sees a "warning" toast "<title>" saying "Re-add it if you want that terminal output included."

    Examples:
      | count                 | title                                        |
      | one terminal excerpt  | Expired terminal context omitted from message  |
      | two terminal excerpts | Expired terminal contexts omitted from message |

  @backlog @desktop
  Scenario: A draft holding only expired terminal excerpts is not sent
    Given the draft holds nothing but a terminal excerpt whose text is gone
    When the user sends the message
    Then nothing is sent and the draft is kept
    And the user sees a "warning" toast "Expired terminal context won't be sent" saying "Remove it or re-add it to include terminal output."

  @backlog @desktop
  Scenario: Drafts saved by older versions keep their terminal excerpts
    Given a draft saved before excerpts were inline links
    When the user opens that draft
    Then each excerpt appears where its placeholder was
    And leftover placeholders disappear

  @tui
  Scenario: The user adds terminal output to the prompt in the terminal client
    Given the terminal client shows a thread's terminal with output
    When the user adds the selected output to the prompt
    Then the prompt gains a removable excerpt naming the terminal

  @backlog @mobile
  Scenario: The user adds terminal output to a message on the phone
    Given the phone shows a thread's terminal
    When the user selects output and adds it to the message
    Then the draft gains an excerpt naming the terminal and lines
