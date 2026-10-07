# Sources:
#   docs/internals/assistant-citations.md
#   apps/web/src/components/ChatView.tsx (Scroll to end, stream does not pull the view back)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Jump to message, Previous turn, Next turn, Load earlier turns)
#   apps/web/src/components/chat/MessagesTimeline.logic.ts
#   apps/web/src/components/ChatMarkdown.tsx (file links, Copy as Markdown, Copy as CSV, code block copy and wrap)
#   apps/web/src/components/chat/externalLinkContextMenu.ts (Open in integrated browser, Open in system browser, Copy Link)
#   apps/web/src/components/chat/AssistantSelectionToolbar.tsx (Cite selection in composer, Selection is too long to cite)
#   apps/web/src/components/chat/AssistantCitationChip.tsx
#   apps/web/src/components/chat/AssistantCitationSource.tsx (Could not open the cited response, The quoted text has changed)
#   apps/web/src/components/chat/AssistantCitationCommentEditor.tsx
#   apps/tui/src/timelineLinks.ts (bare URLs become terminal hyperlinks)
#   apps/tui/src/components/MessagesTimeline.tsx (windowing, earlier and newer entries, sticks to the bottom)
#   apps/desktop-qt/qml/HalC2/Bricks/js/markdown.js (bare web addresses become links outside code)
#   apps/desktop-qt/qml/HalC2/Bricks/Markdown.qml (Cite on a selection of a reply)
#   apps/desktop-qt/tests/native/features/MarkdownSteps.cpp
#   apps/server-ex/lib/hal_c2/web/socket.ex (thread stream subscriptions, merged bursts, resync from offset)
#   apps/server-ex/lib/hal_c2/streams/view.ex (a window over a thread's newest runs, `more` and `page`)
#   apps/desktop-qt/src/native/TimelineModel.cpp (windowItems, hasEarlier, loadEarlier)
#   apps/desktop-qt/qml/HalC2/Bricks/Timeline.qml (earlier turns load at the top)

Feature: Moving through a thread and following links
  A long thread stays easy to read while the agent writes. The view follows new output
  until the user scrolls away, and links, files and quoted replies lead where they point.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a long thread in "shop"

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario: The view follows new output while the user is at the end
    Given the user is at the end of the thread
    When the agent writes more of its reply
    Then the new text stays in view

  @shared @backlog-mobile @backlog-tui
  Scenario: Scrolling away stops the view from following
    Given the agent is writing its reply
    When the user scrolls up to an earlier message
    Then the view stays on that message while the reply grows
    And the user is offered a way to scroll to the end

  @shared @backlog-mobile @backlog-tui
  Scenario: The user returns to the end of the thread
    Given the user has scrolled away from the end while the agent writes
    When the user scrolls to the end
    Then the latest output is shown
    And the view follows new output again

  @shared @backlog-mobile @backlog-tui
  Scenario: A long thread opens as its newest turns
    Given the thread has more turns than a client loads at once
    When the user opens it again
    Then the client asks its MC for the newest turns only
    And only those turns are sent and shown

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario: Earlier turns load when the user reaches the top
    Given the thread has more turns than are loaded
    When the user loads earlier turns
    Then the user sees that earlier turns are loading
    And the earlier turns appear above without moving the message being read

  @shared @backlog-mobile @backlog-tui
  Scenario: A thread that does not fill the view loads earlier turns by itself
    Given the thread has more turns than are loaded
    When what is loaded leaves room in the view
    Then the earlier turns are loaded without the user scrolling

  @desktop @backlog
  Scenario: The user jumps between turns
    Given the thread has ten turns
    When the user jumps to the third message
    Then the third message is shown
    When the user moves to the next turn
    Then the fourth turn is shown
    When the user moves to the previous turn
    Then the third turn is shown

  # TUI: implemented in apps/tui/src/timelineLinks.ts
  @shared @backlog-mobile @backlog-tui
  Scenario: A bare web address in a message can be opened
    When the agent writes "see https://example.com/docs"
    Then "https://example.com/docs" can be opened as a link
    And web addresses inside code are left as text

  @desktop @backlog
  Scenario Outline: The user chooses where a web link opens
    Given the agent's reply links to "https://example.com/docs"
    When the user chooses to <choice>
    Then <result>

    Examples:
      | choice                        | result                                         |
      | open it in the app            | the page opens in the thread's browser         |
      | open it in the system browser | the page opens in the system browser           |
      | copy the link                 | "https://example.com/docs" is on the clipboard |

  @desktop @backlog
  Scenario Outline: A file mentioned by the agent can be followed
    Given the agent's reply links to the file "src/cart.ts"
    When the user chooses to <choice>
    Then <result>

    Examples:
      | choice                 | result                                   |
      | open it in the editor  | "src/cart.ts" opens in the user's editor |
      | copy its relative path | "src/cart.ts" is on the clipboard        |
      | copy its full path     | the absolute path is on the clipboard    |

  @shared @backlog-mobile @backlog-tui
  Scenario: The user cites part of a reply in the next message
    When the user selects a sentence in the agent's reply and cites it
    Then the composer holds a citation of that sentence
    And the user can add a comment to the citation

  @shared @backlog
  Scenario Outline: Following a citation to its source
    Given the user's message cites a sentence from an earlier reply
    And the cited reply <state>
    When the user follows the citation
    Then <result>

    Examples:
      | state                      | result                                                                       |
      | is unchanged               | the earlier reply is shown with the sentence highlighted                     |
      | has been edited            | the earlier reply is shown with "The quoted text has changed"                |
      | is no longer in the thread | the quote is still readable and "Could not open the cited response" is shown |

  @mc
  Scenario: A client following a thread receives its live updates
    Given a client is following the thread
    When the agent writes more of its reply
    Then the client receives the new text without asking again
    And a burst of streamed text arrives as one update

  @mc
  Scenario: A client that falls behind catches up from where it was
    Given a client is following a thread whose agent streams faster than the client reads
    When the client falls too far behind
    Then the client is told to resync
    And it receives everything since its last position without gaps
