# Sources:
#   apps/web/src/components/ChatMarkdown.tsx (code block header, Copy code, line wrap, table expand and copy, streaming)
#   apps/web/src/index.css (.chat-markdown: headings, lists, quotes, inline code, code blocks, tables)
#   apps/web/src/markdown-clipboard.ts (Copy as Markdown, Copy as CSV)
#   apps/web/src/markdown-github-alerts.ts (Note, Tip, Important, Warning, Caution)
#   apps/web/src/markdown-incremental.ts (a reply being written parses only what changed)
#   apps/desktop-qt/qml/HalC2/Bricks/Markdown.qml
#   apps/desktop-qt/qml/HalC2/Bricks/js/markdown.js (escaping, safe links, streaming segments)
#   apps/desktop-qt/tests/tst_Markdown.qml
#   apps/desktop-qt/tests/native/features/MarkdownSteps.cpp

Feature: Formatted messages
  Messages are written in Markdown. The timeline shows headings, lists, quotes, code and
  tables formatted, lets the user copy code and tables, and never lets a message's text
  load anything or pass itself off as something it is not.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  @shared @backlog-mobile
  Scenario: A reply shows its formatting
    When the agent answers with a heading, a list, a quote, a code block and a table
    Then the heading and the list are shown as text
    And the quote, the code block and the table are each shown in their own form

  @shared @backlog-mobile
  Scenario: The user copies a code block
    Given the agent's reply has a code block
    When the user copies the code block
    Then the code block's source is on the clipboard
    And the code block shows it was copied

  @shared @backlog-mobile @backlog-tui
  Scenario: Line wrap in a code block can be turned off and on
    Given the agent's reply has a code block with a long line
    When the user turns line wrap off for the code block
    Then the long line scrolls sideways
    When the user turns line wrap on for the code block
    Then the long line wraps

  @shared @backlog-mobile
  Scenario Outline: The user copies a table
    Given the agent's reply has a table
    When the user copies the table as <format>
    Then the table is on the clipboard as <format>

    Examples:
      | format   |
      | Markdown |
      | CSV      |

  @shared @backlog-mobile
  Scenario: Table cells can be collapsed and expanded
    Given the agent's reply has a table with a long cell
    When the user collapses the table cells
    Then the long cell stays on one line
    When the user expands the table cells
    Then the long cell wraps

  @shared @backlog-mobile
  Scenario: Markup in a message is shown as it was written
    When the agent answers with HTML and an image
    Then the HTML is shown as written
    And the image is a link to its address and nothing is loaded from the web

  @shared @backlog-mobile
  Scenario: A link to a script is not a link
    When the agent answers with a link to "javascript:alert(1)"
    Then the link's text is shown and nothing can be opened

  @shared @backlog-mobile @backlog-tui
  Scenario: A reply being written keeps what is already shown
    Given the agent is writing a reply of several paragraphs
    When the reply grows by another paragraph
    Then the paragraphs already shown are not drawn again

  @shared @backlog-mobile
  Scenario: A code block is shown as code while it is written
    Given the agent is writing a code block
    Then the code written so far is shown as a code block
    When the agent closes the code block
    Then the same code block is shown, finished

  @shared @backlog-mobile
  Scenario Outline: A GitHub alert shows its kind
    When the agent answers with a "<marker>" alert
    Then the quote is titled "<title>"

    Examples:
      | marker    | title     |
      | NOTE      | Note      |
      | TIP       | Tip       |
      | IMPORTANT | Important |
      | WARNING   | Warning   |
      | CAUTION   | Caution   |

  @shared @backlog-mobile
  Scenario: A user message keeps its line breaks
    Given the user's message has two lines
    Then the message is shown on two lines
