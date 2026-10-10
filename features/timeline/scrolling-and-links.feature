# Sources:
#   docs/internals/assistant-citations.md
#   apps/web/src/components/ChatView.tsx (Scroll to end, stream does not pull the view back)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Jump to message, Previous turn, Next turn, Load earlier turns)
#   apps/web/src/components/chat/MessagesTimeline.logic.ts
#   apps/web/src/components/ChatMarkdown.tsx (file links, Copy as Markdown, Copy as CSV, code block copy and wrap)
#   apps/web/src/components/chat/externalLinkContextMenu.ts (Open in integrated browser, Open in system browser, Copy Link)
#   apps/web/src/components/chat/AssistantSelectionToolbar.tsx (Cite selection in composer, Selection is too long to cite)
#   apps/web/src/lib/selectionActions.ts, apps/web/src/lib/assistantTextSelection.ts (when the cite action opens, what a quote holds, finding a quote again)
#   apps/web/src/components/chat/AssistantCitationChip.tsx
#   apps/web/src/components/chat/AssistantCitationSource.tsx (Could not open the cited response, The quoted text has changed)
#   apps/web/src/components/chat/AssistantCitationCommentEditor.tsx
#   apps/web/src/components/chat/useAssistantCitationTarget.ts (loading earlier turns for a citation, giving up, cancelling the positioning)
#   apps/web/src/components/chat/timelineScrollAnchoring.ts (remembered positions, framing a new turn)
#   apps/web/src/components/chat/timelineScrollTarget.ts
#   apps/web/src/components/chat/pageScrollController.ts (page keys, held-key acceleration, nested scrolling)
#   apps/web/src/components/chat/timelineMinimapItems.ts (the turn index and its preview)
#   apps/tui/src/timelineLinks.ts (bare URLs become terminal hyperlinks)
#   apps/tui/src/components/MessagesTimeline.tsx (windowing, earlier and newer entries, sticks to the bottom)
#   apps/desktop-qt/qml/HalC2/Bricks/js/markdown.js (bare web addresses become links outside code)
#   apps/desktop-qt/qml/HalC2/Bricks/Markdown.qml (Cite on a selection of a reply)
#   apps/desktop-qt/tests/native/features/MarkdownSteps.cpp
#   apps/server-ex/lib/hal_c2/web/socket.ex (thread stream subscriptions, merged bursts, resync from offset)
#   apps/server-ex/lib/hal_c2/streams/view.ex (a window over a thread's newest runs, `more` and `page`)
#   apps/desktop-qt/src/native/TimelineModel.cpp (windowItems, hasEarlier, loadEarlier)
#   apps/desktop-qt/qml/HalC2/Bricks/Timeline.qml (earlier turns load at the top, another thread opens at its end)
#   apps/mobile/src/features/threads/ThreadFeed.tsx (load earlier activity control and its error)

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
  Scenario: Another thread opens at its end however far the last was scrolled
    Given the user has scrolled away from the end of the thread
    When the user opens another thread
    Then the other thread shows its latest output
    And the composer is not resting

  @desktop @backlog
  Scenario: A thread opens where the user left it
    Given the user read an earlier message of the thread "Cart totals" and left it there
    And the user had opened one folded turn's work
    When the user comes back to "Cart totals"
    Then the same message is at the same place in the view
    And the work the user had opened is still open

  @desktop @backlog
  Scenario: A thread the user left at its end opens following new output
    Given the user left the thread "Cart totals" at its end
    When the user comes back to "Cart totals" after the agent wrote more
    Then the view shows the latest output
    And the view follows new output

  @desktop @backlog
  Scenario: Only the most recent threads are remembered
    Given the user has left more than 100 threads partway through
    When the user comes back to the one left longest ago
    Then it opens at its end
    And the 100 threads left most recently still open where they were left

  @desktop @backlog
  Scenario: A message the user just sent is framed at the top of the view
    Given the user is looking at the end of a long thread
    When the user sends "also update the changelog"
    Then the sent message is placed near the top of the view
    And the agent's reply grows beneath it without the view jumping

  @desktop @backlog
  Scenario: The framed turn gives way to following once the agent starts working
    Given the user sent a message and it is framed at the top of the view
    When the agent starts running tool calls
    Then the view moves to the end and follows the new output

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

  @backlog @mobile
  Scenario: Earlier turns that fail to load say why and can be asked for again
    Given the thread has more turns than are loaded
    When the user loads earlier turns and the MC refuses
    Then the user is told why the earlier turns could not be loaded
    And the user can ask for the earlier turns again

  @backlog @mobile
  Scenario: Nothing is offered once every turn is loaded
    Given every turn of the thread is loaded
    Then no way to load earlier turns is offered

  # Proved by tst_Timeline.qml (test_pageKeysScrollTheConversation), not yet by a step (hal-c2/hal-c2#213).
  @desktop @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: The keyboard pages through the conversation
    Given a long thread with the keyboard on it
    When the user presses Page Up, Home, Page Down and End
    Then the view scrolls a page up, to the start, a page down and to the end
    And the view follows new output again once it is at the end

  # Proved by tst_Composer.qml (test_pageKeysGoToTheConversation), not yet by a step (hal-c2/hal-c2#213).
  @desktop @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: Page Up and Page Down from the composer scroll the conversation
    Given the user is typing a short message in the composer
    When the user presses Page Up
    Then the conversation scrolls a page up
    And the composer keeps the keyboard

  # Proved by tst_Timeline.qml (test_jumpToTheEndIsAKeyboardButton), not yet by a step (hal-c2/hal-c2#213).
  @desktop @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: The scroll-to-end control is a button
    Given the user has scrolled away from the end
    Then "Scroll to end" is a raised button the keyboard reaches
    And pressing it with the keyboard returns to the end

  @desktop @backlog
  Scenario: The user jumps between turns
    Given the thread has ten turns
    When the user jumps to the third message
    Then the third message is shown
    When the user moves to the next turn
    Then the fourth turn is shown
    When the user moves to the previous turn
    Then the third turn is shown

  @desktop @backlog
  Scenario: Pointing at the turn index previews the turn
    Given the thread has ten turns
    When the user points at the index of the fourth turn
    Then the fourth turn's message is previewed on one line
    And the start of that turn's final reply is previewed beneath it
    When the user chooses it
    Then the fourth turn is shown

  @desktop @backlog
  Scenario: The turn index can be driven from the keyboard
    Given the thread has ten turns
    And the user focused the turn index
    When the user presses Down twice and then Enter
    Then the third turn is shown

  @desktop @backlog
  Scenario: A thread with a single turn has no turn index
    Given the thread has one turn
    Then the view offers no turn index

  @desktop @backlog
  Scenario: Page keys scroll the timeline by a page
    Given the thread is longer than the view
    When the user presses Page Down
    Then the view scrolls down by almost one page
    When the user presses Page Up
    Then the view scrolls back up by almost one page

  @desktop @backlog
  Scenario: Holding a page key scrolls faster the longer it is held
    Given the thread is longer than the view
    When the user holds Page Down for half a second
    Then the view scrolls faster than for a single press
    And it never scrolls faster than twice the pace of a single press

  @desktop @backlog
  Scenario Outline: Page keys leave the timeline alone when something else is using them
    Given the thread is longer than the view
    And <situation>
    When the user presses <keys>
    Then the thread does not scroll

    Examples:
      | situation                                                  | keys                    |
      | the user is typing a long prompt that can scroll itself    | Page Down               |
      | the user is composing text with an input method            | Page Down               |
      | the user holds a modifier key                              | Shift and Page Down     |

  @desktop @backlog
  Scenario: A scrollable block inside a reply keeps the scroll until it has no more to give
    Given the agent's reply has a code block that scrolls sideways or vertically
    When the user scrolls over the code block
    Then the code block scrolls
    When the code block cannot scroll any further in that direction
    Then the thread scrolls instead

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

  @desktop @backlog
  Scenario: A selection too long to cite says so
    Given the user selected more than 8,000 characters of the agent's reply
    Then the cite action reads "Shorten selection" and cannot be used

  # Legacy: apps/web/src/lib/selectionActions.ts, assistantTextSelection.ts (captureAssistantTextSelection)
  @backlog @desktop
  Scenario: The cite action waits until the mouse is released
    Given the user is dragging to select a sentence of the agent's reply
    Then the cite action is not shown while the button is held
    When the user releases the mouse button
    Then the cite action appears beside where the button was released

  @backlog @desktop
  Scenario: A double click is given time to become a triple click before the cite action appears
    When the user double-clicks a word of the agent's reply
    Then the cite action appears only after half a second without a third click
    When the user clicks a third time within that half second
    Then the cite action appears once, for the paragraph the third click selected

  @backlog @desktop
  Scenario Outline: A selection that cannot belong to one reply is not offered for citation
    Given the user selected text that <reaches>
    Then no cite action is offered

    Examples:
      | reaches                                          |
      | runs from one agent reply into another           |
      | includes a button, field or other control's text |

  @backlog @desktop
  Scenario: Buttons and hidden text inside a reply are left out of the quote
    Given the agent's reply has a copy button and hidden text between two paragraphs
    When the user selects from the first paragraph to the second and cites it
    Then the quote holds both paragraphs without the button's label or the hidden text

  @backlog @desktop
  Scenario Outline: The cite action goes away when the user does something else
    Given the cite action is shown for a selected sentence
    When the user <does>
    Then the cite action goes away

    Examples:
      | does                       |
      | scrolls the thread         |
      | right-clicks               |
      | resizes the window         |
      | switches to another window |
      | presses Escape             |

  # Legacy: apps/web/src/lib/assistantTextSelection.ts (findAssistantCitationText)
  @backlog @desktop
  Scenario: A sentence that appears twice in a reply is found by the words around it
    Given the user cited a sentence that appears twice in the same reply
    And the words just before or after the cited one differ from the other
    When the user follows the citation
    Then the occurrence the user cited is highlighted

  @backlog @desktop
  Scenario: A cited sentence that cannot be told apart from another is not guessed
    Given the user cited a sentence that appears twice in the same reply with the same words around it
    When the user follows the citation
    Then the reply is shown without a highlight
    And the user is told "The quoted text has changed"

  @backlog @desktop
  Scenario: A citation is still found after the reply's text is reflowed
    Given the user cited lines of code from a reply
    And the reply's indentation, tabs or line endings have changed since
    When the user follows the citation
    Then the cited lines are highlighted

  @backlog @desktop
  Scenario: A citation the composer cannot take is refused
    Given the composer cannot take text because the agent is waiting on an answer
    When the user selects a sentence in the agent's reply and cites it
    Then the user is told "The composer is not ready" and to try again once that is resolved
    And the draft is unchanged

  @desktop @backlog
  Scenario: The cite action can be reached and dismissed from the keyboard
    Given the user selected a sentence of the agent's reply
    When the user presses Tab
    Then focus moves to the cite action
    When the user presses Escape
    Then the cite action goes away and the selection stays

  @desktop @backlog
  Scenario: A citation in the draft shows a short form of what it quotes
    Given the draft cites a paragraph of 200 characters with no comment
    Then the citation shows its first 64 characters followed by an ellipsis
    And pointing at the citation offers "View source"
    When the user adds the comment "Too slow?"
    Then the citation shows "Too slow?" instead

  @desktop @backlog
  Scenario Outline: A citation's comment is written with the keyboard
    Given the user is writing the comment of a citation
    When the user presses <keys>
    Then <result>

    Examples:
      | keys                       | result                                   |
      | Enter                      | the comment is saved                     |
      | Command or Control + Enter | the comment is saved and the message is sent |
      | Shift + Enter              | a new line is added to the comment       |
      | Escape                     | the comment is not changed               |

  @desktop @backlog
  Scenario: A comment over the limit cannot be saved
    Given the user is writing the comment of a citation
    When the comment is longer than 8,000 characters
    Then the user is told "Comments can contain up to 8,000 characters."
    And saving reads "Shorten comment" and cannot be used

  @desktop @backlog
  Scenario: A comment being written is kept when the user clicks away
    Given the user is writing the comment "Too slow?" of a citation
    When the user clicks elsewhere in the composer
    Then the citation carries the comment "Too slow?"

  @desktop @backlog
  Scenario: Following a citation to a reply that is not loaded yet loads earlier turns
    Given the thread has more turns than are loaded
    And the user's message cites a reply from the oldest turns
    When the user follows the citation
    Then earlier turns are loaded until the cited reply is found
    And the cited reply is shown with the sentence highlighted

  @desktop @backlog
  Scenario: Following a citation gives up after 20 pages of earlier turns
    Given the thread has far more turns than 20 pages hold
    And the user's message cites a reply older than all of them
    When the user follows the citation
    Then the user is told "Could not load the cited response"
    And is told to load earlier turns and click the citation to try again
    And the saved quote is unchanged

  @desktop @backlog
  Scenario Outline: A citation that cannot be followed explains why
    Given the user's message cites <source>
    When the user follows the citation
    Then the user is told "<title>"
    And the selected text is still saved in the citation

    Examples:
      | source                                      | title                                                |
      | a reply that has been removed from the thread | The cited response is unavailable                  |
      | a message the user wrote                    | The citation does not refer to an assistant response |

  @desktop @backlog
  Scenario: Following a citation to a reply inside a folded turn opens the turn
    Given the cited reply is inside a folded turn
    When the user follows the citation
    Then the turn's work is opened
    And the cited reply is shown with the sentence highlighted

  @desktop @backlog
  Scenario Outline: Moving the view cancels a citation that is still being positioned
    Given the user followed a citation and the view is still moving to it
    When the user <moves>
    Then the view stops going to the cited reply
    And the user's own position is kept

    Examples:
      | moves                              |
      | turns the mouse wheel              |
      | drags on a touch screen            |
      | clicks in the thread               |
      | presses an arrow, Page, Home or End key |
      | presses Escape                     |

  @desktop @backlog
  Scenario: The cited sentence is highlighted briefly and then left alone
    When the user follows a citation to an earlier reply
    Then the cited sentence pulses once and stays highlighted for a moment
    And the highlight fades without repainting continuously

  @desktop @backlog
  Scenario: With reduced motion the cited sentence is highlighted without pulsing
    Given the operating system asks for reduced motion
    When the user follows a citation to an earlier reply
    Then the cited sentence is highlighted without a pulse

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
