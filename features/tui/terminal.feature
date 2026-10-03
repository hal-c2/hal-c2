# Sources:
#   apps/tui/src/components/ThreadTerminalDrawer.tsx, ThreadTerminalDrawer.test.tsx
#   apps/tui/src/terminalTabs.ts, terminalTabs.test.ts
#   apps/tui/src/terminalView.ts, terminalView.test.ts (frames, links, cursor, scrollback, paste guard)
#   apps/tui/src/components/ChatView.tsx (terminal palette commands, OSC 52 copy, 6-terminal limit)
#   apps/tui/src/hooks/useKeyBindings.ts (terminal focus routing)
#   apps/tui/src/components/ChatView.layout.ts (MIN_TERMINAL_DRAWER_ROWS)
#   apps/tui/src/features.backlog.test.ts (terminal-session-actions, project-scripts terminal output)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (TUI terminals outliving the session, closed terminals)
#   apps/tui/src/connection.ts (subscribeTerminalMetadata names no MC, so only the connected MC's terminals are listed)
#   apps/server-ex/lib/hal_c2/web/socket.ex (the terminals subscription is per MC)
#   Shared domain: terminal/ owns terminal sessions on every surface.

Feature: Terminal drawer in the terminal client
  Each thread has its own terminals in a drawer under the conversation. The drawer is a
  terminal inside a terminal, so the client only takes the few chords it needs.

  Background:
    Given the terminal client is open on a thread in a project

  @tui
  Scenario: Ctrl+E opens the terminal drawer with focus in the shell
    When the user presses "Ctrl+E"
    Then the terminal drawer opens with one terminal
    And keys typed go to the shell

  @tui
  Scenario: Ctrl+E hides the drawer and keeps the shell running
    Given the terminal drawer is open with a long-running command
    When the user presses "Ctrl+E"
    Then the drawer hides
    And the command keeps running

  @tui
  Scenario: Ctrl+P moves focus between the prompt and the terminal
    Given the terminal drawer has focus
    When the user presses "Ctrl+P"
    Then the prompt has focus
    And pressing "Ctrl+P" again returns focus to the terminal

  @tui
  Scenario: Opening a thread's terminal replays its recent output
    Given the thread's terminal printed output while the drawer was closed
    When the user opens the terminal drawer
    Then the recent output is shown, bounded to the last part of the history

  @tui
  Scenario: The user opens another terminal tab
    Given the terminal drawer has one terminal
    When the user opens a new terminal
    Then a second terminal tab opens and becomes active

  @tui
  Scenario: A thread has at most six terminals
    Given the thread has six terminals
    When the user opens a new terminal
    Then no terminal opens
    And the status line says "At most 6 terminals per thread."

  @tui
  Scenario Outline: The user cycles between terminal tabs
    Given the thread has three terminals with the second active
    When the user switches to the <direction> terminal
    Then the <result> terminal is active

    Examples:
      | direction | result |
      | next      | third  |
      | previous  | first  |

  @tui
  Scenario: Cycling wraps around at the ends
    Given the thread has three terminals with the third active
    When the user switches to the next terminal
    Then the first terminal is active

  @tui
  Scenario: Switching tabs is instant and keeps each terminal live
    Given two terminals are running commands
    When the user switches from one tab to the other and back
    Then both terminals show their output without a replay

  @tui
  Scenario: Closing the active tab activates the last remaining tab
    Given the thread has three terminals with the second active
    When the user closes the active terminal
    Then the last remaining terminal is active

  @tui
  Scenario: Closing an inactive tab leaves the active one alone
    Given the thread has three terminals with the first active
    When the user closes the third terminal
    Then the first terminal is still active

  @tui
  Scenario: Closing the last terminal closes the drawer
    Given the thread has one terminal
    When the user closes it
    Then the terminal drawer closes

  @tui
  Scenario: Terminals opened on another client appear as tabs
    Given the terminal drawer is open with one terminal
    When another client opens a terminal on the same thread
    Then a second tab appears and the active tab does not change

  @tui
  Scenario: A terminal closed on another client disappears
    Given the thread has two terminals
    When another client closes the second terminal
    Then its tab disappears

  @tui
  Scenario: Terminals of a thread on another MC of the cluster appear as tabs
    Given the terminal client is connected to one MC of a cluster
    And the thread runs on another MC of the cluster
    When another client opens a terminal on that thread
    Then a tab for it appears in the terminal client

  @tui
  Scenario Outline: Palette terminal actions target the active terminal exactly
    Given the thread has two terminals with the second active
    When the user chooses "<command>" from the command palette
    Then only the second terminal is <result>

    Examples:
      | command          | result                       |
      | Clear terminal   | cleared                      |
      | Restart terminal | restarted with a fresh shell |
      | Close terminal   | closed                       |

  @tui
  Scenario: A server-side clear removes stale output
    Given the terminal shows output
    When the session is cleared from any client
    Then the old output disappears from the drawer

  @tui
  Scenario: The user scrolls back through terminal output
    Given the terminal has more output than fits
    When the user presses "Shift+PgUp"
    Then older output is shown and the cursor is hidden

  @tui
  Scenario: Typing snaps the terminal back to the live output
    Given the user scrolled back in the terminal
    When the user types "ls"
    Then the terminal shows the live output again
    And "ls" reaches the shell

  @tui
  Scenario: Plain PgUp and arrow keys still reach the running program
    Given a pager is running in the terminal
    When the user presses "PgUp"
    Then the pager receives the key

  @tui
  Scenario: Ctrl+O copies what the terminal shows
    Given the terminal is scrolled back to earlier output
    When the user presses "Ctrl+O"
    Then the visible terminal text is copied to the clipboard
    And the status line says "Terminal copied to clipboard."

  @tui
  Scenario: Copying stays on the scrolled-back view while output keeps arriving
    Given the user scrolled back and output is still arriving
    When the user presses "Ctrl+O"
    Then the copied text is the scrolled-back view, not the live tail

  @tui
  Scenario Outline: Copying explains why nothing was copied
    Given <condition>
    When the user presses "Ctrl+O" in the terminal
    Then the status line says "<message>"

    Examples:
      | condition                                             | message                                   |
      | the terminal is empty                                 | Terminal is empty.                        |
      | the user's terminal does not support clipboard writes | Clipboard not supported by this terminal. |

  @tui
  Scenario: Pasting into the terminal cannot break out of bracketed paste
    Given the shell has bracketed paste on
    When the user pastes text that contains a bracketed paste end marker
    Then the end marker is removed before the text reaches the shell

  @tui
  Scenario: URLs printed in the terminal are clickable, even when they wrap
    Given the terminal printed a URL that wraps across two rows
    Then clicking either row opens the complete URL

  @tui
  Scenario: The shell cursor stays visible
    Given the shell cursor is on a blank cell or over text
    Then the cursor is drawn as a visible block

  @tui
  Scenario: Terminal colours follow the user's terminal theme
    Given the shell prints text in ANSI colours and in truecolor
    Then ANSI colours use the user's terminal palette
    And truecolor text keeps its exact colour

  @tui
  Scenario: The focused drawer's header names the terminal and its keys
    Given the terminal is 120 columns wide
    And the terminal drawer has focus
    Then the drawer's first row reads "Terminal · Thread one · ^P prompt · ^E close · ^↑/^↓ resize · ^O copy · paste ✓"
    And "Terminal · Thread one" is in the accent colour and the rest in the dim colour

  @tui
  Scenario: An unfocused drawer's header is in the warning colour
    Given the terminal is 120 columns wide
    And the terminal drawer has focus
    When the user presses "Ctrl+P"
    Then the drawer's first row reads "Terminal · Thread one · ^P focus · ^E close"
    And "Terminal · Thread one" is in the warning colour and the rest in the dim colour

  @tui
  Scenario: A narrow drawer cuts its key hint short
    Given the terminal is 60 columns wide
    And the terminal drawer has focus
    Then the drawer's first row reads "Terminal · Thread one · ^P prompt · ^E close · ^↑/^↓ re…"

  @tui
  Scenario: A long thread title is cut to the drawer's width
    Given the thread is titled "Fix the flaky checkout test in the payments service"
    And the terminal is 60 columns wide
    And the terminal drawer has focus
    Then the drawer's first row reads "Terminal · Fix the flaky checkout test in the payments …"

  @tui
  Scenario: The active terminal tab is marked in the accent colour
    Given the thread has two terminals with the first active
    Then the drawer's second row reads "▸ 1 ✕   2 + new"
    And the tab marker "▸" is in the accent colour and its number in the text colour
    And the other tab's number is in the dim colour

  @tui
  Scenario: Terminals that outlived the client come back as tabs
    Given a thread whose terminals outlived the terminal client session
    When the terminal client opens the thread
    Then its tabs list every terminal the MC kept

  @tui
  Scenario: A terminal the user closed does not come back
    Given the user closed a terminal
    When the terminal client lists the thread's terminals again
    Then the closed terminal is gone

  @tui
  Scenario: The user adds selected terminal output to the prompt
    Given the user selected lines of terminal output
    When the user adds the selection to the prompt
    Then a bounded chip with that output is attached to the prompt
