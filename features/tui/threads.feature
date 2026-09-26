# Sources:
#   apps/tui/src/components/Sidebar.tsx, Sidebar.logic.ts, Sidebar.test.tsx, Sidebar.logic.test.ts
#   apps/tui/src/store.ts, store.test.ts (flat list, selection, filter)
#   apps/tui/src/components/ChatView.tsx (thread context menu, palette thread actions)
#   apps/tui/src/components/ContextMenu.tsx, ContextMenu.test.tsx
#   apps/tui/src/components/ThreadOverlays.tsx (confirm delete)
#   apps/tui/src/commands.ts, commands.test.ts (palette fuzzy ranking)
#   apps/tui/src/components/CommandPalette.tsx, CommandPalette.test.tsx
#   apps/tui/src/features.backlog.test.ts (archived-threads)
#   Shared domain: threads/ owns thread lifecycle; navigation/command-palette.feature owns the palette.

Feature: Thread list and thread actions in the terminal
  The thread list is one flat list the keyboard can walk. Thread actions live in the command
  palette and in a context menu, and each one that changes a thread can be undone.

  Background:
    Given the terminal client is connected to an environment with several threads

  @tui
  Scenario: The thread list is flat and stable by creation time
    Given threads were created in the order "Alpha", "Beta", "Gamma"
    When "Alpha" receives a new message
    Then the thread list order does not change

  @tui
  Scenario: The first thread opens when the client connects
    When the first snapshot arrives
    Then the first thread in the list is selected and open
    And the status line reports how many projects were loaded

  @tui
  Scenario: Threads are shelved as active, snoozed and settled
    Given active, snoozed and settled threads
    Then the list shows the active threads, then the snoozed shelf, then the settled shelf

  @tui
  Scenario: A selected snoozed thread stays visible when its shelf is collapsed
    Given the snoozed shelf is collapsed
    And the selected thread is snoozed
    Then the selected thread is still shown in the list

  @tui
  Scenario: A long settled shelf pages and keeps a deep selection
    Given more settled threads than the shelf shows at first
    When the user selects a settled thread beyond the first page
    Then the shelf shows enough pages to keep that thread visible

  @tui
  Scenario: A snoozed thread moves back when it wakes
    Given a thread snoozed until 10:00
    When the clock reaches 10:00
    Then the thread moves to the active threads without the user doing anything

  @tui
  Scenario: The user scopes the list to one project
    When the user scopes the thread list to the project "shop"
    Then only threads in "shop" are listed

  @tui
  Scenario: Search and project scope filter the same list
    Given the thread list is scoped to "shop"
    When the user filters threads by "login"
    Then only threads in "shop" whose title matches "login" are listed
    And the search shows the active query

  @tui
  Scenario: Cancelling the filter restores the full list
    Given the user is filtering threads by "login"
    When the user presses "Esc"
    Then the filter is cleared and every thread is listed again

  @tui
  Scenario: A filter that hides the selected thread moves the selection to a match
    Given the thread "Alpha" is selected
    When the user filters threads by "Beta"
    Then "Beta" is selected

  @tui
  Scenario: Walking past the visible edge scrolls the list
    Given more threads than fit on screen
    When the user moves to the next thread past the bottom edge
    Then the list scrolls to keep the selected thread in view

  @tui
  Scenario: Jumping to a thread number counts visible threads only
    Given the first project is expanded
    When the user presses "Alt+2"
    Then the second visible thread is selected

  @tui
  Scenario Outline: The thread context menu offers the actions that apply
    Given a thread that <condition>
    When the user opens its context menu
    Then "<item>" is <availability>

    Examples:
      | condition                              | item            | availability |
      | has no workspace folder                | Copy path       | disabled     |
      | has a workspace folder                 | Copy path       | enabled      |
      | has no branch                          | Copy branch     | absent       |
      | is on the branch "fix/login"           | Copy branch     | enabled      |
      | is running a turn                      | Archive thread  | disabled     |
      | is idle                                | Archive thread  | enabled      |
      | is on a server without settlement      | Settle thread   | absent       |

  @tui
  Scenario: The context menu stays inside the terminal
    Given a thread near the bottom right of the terminal
    When the user opens its context menu
    Then the whole menu is drawn inside the terminal

  @tui
  Scenario Outline: Copy actions put thread facts on the clipboard
    When the user chooses "<item>" for a thread
    Then the clipboard holds the thread's <value>

    Examples:
      | item           | value            |
      | Copy path      | workspace folder |
      | Copy branch    | branch name      |
      | Copy thread ID | thread id        |

  @tui
  Scenario: The user renames a thread
    When the user renames the thread "Alpha" to "Login fix"
    Then the thread is listed as "Login fix"

  @tui
  Scenario: Cancelling a rename keeps the old title
    Given the user is renaming the thread "Alpha"
    When the user presses "Esc"
    Then the thread is still called "Alpha"

  @tui
  Scenario: The user settles a thread
    Given the server supports settling threads
    When the user settles the thread "Alpha"
    Then "Alpha" moves to the settled shelf
    And the status line says "Settled."

  @tui
  Scenario: The user un-settles a thread
    Given the thread "Alpha" is settled
    When the user un-settles "Alpha"
    Then "Alpha" returns to the active threads
    And the status line says "Un-settled."

  @tui
  Scenario: The server refuses to settle a thread that needs attention
    Given the thread "Alpha" is waiting on an approval
    When the user settles "Alpha"
    Then "Alpha" stays active
    And the status line shows the server's reason as an error

  @tui
  Scenario: The user archives the open thread
    When the user archives the open thread "Alpha"
    Then "Alpha" leaves the thread list
    And the status line says "Archived."

  @tui
  Scenario: The user unarchives the thread that is still open
    Given the user archived the open thread "Alpha" and it is still open
    When the user unarchives it from the command palette
    Then "Alpha" returns to the thread list
    And the status line says "Unarchived."

  @tui
  Scenario: Deleting a thread asks for confirmation
    When the user deletes the thread "Alpha"
    Then the client warns and asks to confirm with "y" or "n"

  @tui
  Scenario: Confirming the delete removes the thread
    Given the client is asking to confirm deleting "Alpha"
    When the user presses "y"
    Then "Alpha" is deleted and leaves the list

  @tui
  Scenario Outline: Declining the delete keeps the thread
    Given the client is asking to confirm deleting "Alpha"
    When the user presses "<key>"
    Then "Alpha" is still listed

    Examples:
      | key |
      | n   |
      | Esc |

  @tui
  Scenario: The user stops a running session from the palette
    Given the open thread is running a turn
    When the user stops the session from the command palette
    Then the turn stops
    And the status line says "Session stopped."

  @tui
  Scenario Outline: The command palette ranks matches by how well they fit
    Given the command palette is open
    When the user types "<query>"
    Then "<command>" is listed <rank>

    Examples:
      | query | command        | rank                         |
      | new   | New thread     | first                        |
      | filt  | Filter threads | first                        |
      | nthd  | New thread     | as a fuzzy subsequence match |
      | park  | Settle thread  | through its keywords         |

  @tui
  Scenario: A palette query with no matches says so
    Given the command palette is open
    When the user types "zzzz"
    Then the palette shows that there are no matching commands

  @backlog @tui
  Scenario: The user browses archived threads with search and sort
    When the user opens archived threads
    Then archived threads are listed with search and sort by date

  @backlog @tui
  Scenario: The user unarchives or deletes a thread from the archive
    Given the archive lists the thread "Old spike"
    When the user unarchives "Old spike"
    Then "Old spike" returns to the thread list
