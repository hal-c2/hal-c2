# Sources:
#   docs/user/terminal.md
#   apps/tui/src/terminalTabs.ts (addTab, closeTab, cycleActiveId, tabsWithDiscovered, reduceKnownTerminals)
#   apps/tui/src/terminalTabs.test.ts
#   apps/tui/src/components/ChatView.tsx (newTerminal, selectTerminal, closeTerminal, MAX_TERMINALS_PER_THREAD, palette entries)
#   apps/tui/src/components/ThreadTerminalDrawer.tsx (every tab stays mounted)
#   apps/tui/src/features.backlog.test.ts (terminal-session-actions)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (terminal-list)
#   apps/web/src/components/ThreadTerminalDrawer.tsx (splits, MAX_TERMINALS_PER_GROUP)
#   apps/web/src/components/ThreadTerminals.tsx (hidden threads keep terminals mounted)
#   apps/web/src/components/useThreadTerminalActions.ts
#   apps/web/src/terminalUiStateStore.ts (terminal groups, active terminal, open and height per thread)
#   apps/web/src/terminal/ghostty/surface.ts (click on a split pane focuses it)
#   apps/web/src/lib/terminalCloseConfirm.ts
#   packages/shared/src/terminalLabels.ts
#   apps/web/src/rightPanelStore.ts (terminal surfaces: a right panel tab per terminal group)
#   apps/desktop-qt/src/native/TerminalController.cpp (split groups, panel groups)
#   apps/desktop-qt/src/native/RightPanelController.cpp (terminal:<group> tabs)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalSplits.qml
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalDrawer.qml
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalPanel.qml
#   apps/desktop-qt/tests/native/features/TerminalSteps.cpp
#   Cross-domain: navigation/ and tui/keymap.feature own the terminal key chords.

Feature: Terminal tabs and splits
  A thread can run several terminals at once. Each one is its own shell with its own history,
  and switching between them never loses output.

  Rule: The terminal client keeps a row of numbered terminals per thread

    Background:
      Given the terminal client shows a thread with its terminal open

    @tui
    Scenario: The user opens another terminal on the thread
      Given the thread has one terminal
      When the user opens a new terminal
      Then the thread has two terminals
      And the new terminal is the active one

    @tui
    Scenario: A new terminal takes the next free number
      Given the thread has terminals 1 and 3
      When the user opens a new terminal
      Then the new terminal is number 4

    @tui
    Scenario: The terminal client stops at six terminals per thread
      Given the thread has six terminals
      When the user opens a new terminal
      Then no terminal is added
      And the user is told "At most 6 terminals per thread."

    @tui
    Scenario Outline: The user steps between a thread's terminals
      Given the thread has terminals 1, 2 and 3
      And terminal <from> is active
      When the user moves to the <direction> terminal
      Then terminal <to> is active

      Examples:
        | from | direction | to |
        | 1    | next      | 2  |
        | 3    | next      | 1  |
        | 1    | previous  | 3  |

    @tui
    Scenario: Stepping between terminals is not offered with only one terminal
      Given the thread has one terminal
      Then the user is not offered next or previous terminal

    @tui
    Scenario: Switching terminals keeps background output
      Given terminal 2 is running a build while terminal 1 is active
      When the user switches to terminal 2
      Then terminal 2 shows everything the build printed while it was in the background

    @tui
    Scenario: Closing the active terminal activates the last remaining one
      Given the thread has terminals 1, 2 and 3 with terminal 2 active
      When the user closes the active terminal
      Then terminal 2's shell stops on the server
      And terminal 3 is active

    @tui
    Scenario: Closing the last terminal hides the terminal
      Given the thread has one terminal
      When the user closes it
      Then the terminal is hidden
      And focus returns to the prompt

    @tui
    Scenario: Terminals opened elsewhere appear in the terminal client
      Given the terminal client shows terminal 1 for the thread
      When another client opens terminal 2 on the same thread
      Then terminal 2 appears next to terminal 1
      And terminal 1 stays active

    @tui
    Scenario: A terminal closed elsewhere disappears from the terminal client
      Given the terminal client shows terminals 1 and 2 for the thread
      When another client closes terminal 2
      Then only terminal 1 remains

    @tui
    Scenario: Terminals kept from before a server restart are listed again
      Given the thread had terminals 1 and 2 before the MC restarted
      When the terminal client opens the thread
      Then both terminals are listed
      And opening one shows its earlier output

  Rule: The web terminal groups terminals into splits

    @desktop
    Scenario Outline: The user splits the terminal
      Given the thread's terminal is open with one terminal
      When the user splits the terminal <direction>
      Then a second terminal runs next to the first <placement>

      Examples:
        | direction    | placement    |
        | horizontally | side by side |
        | vertically   | stacked      |

    @desktop
    Scenario: A split group holds at most four terminals
      Given a split group with four terminals
      Then the user cannot split that group again
      And the user is told the limit is 4 per group

    @desktop
    Scenario: Closing a terminal asks before stopping its process
      Given the terminal "Terminal 2" is running
      When the user closes it
      Then the user is asked 'Close terminal "Terminal 2"?' and warned its history is cleared
      When the user confirms
      Then its process stops and its history is deleted

    @desktop
    Scenario: Declining the close confirmation keeps the terminal
      Given the terminal "Terminal 2" is running
      When the user closes it and declines the confirmation
      Then "Terminal 2" keeps running with its history

    @desktop
    Scenario: Closing several terminals asks once for all of them
      When the user closes a split group of three terminals
      Then the user is asked once to close 3 terminals, naming each of them

    @backlog @desktop
    Scenario: Closing the right-most active terminal activates the one before it
      Given the thread has terminals 1, 2 and 3 with terminal 3 active
      When the user closes the active terminal
      Then terminal 2 is active

    @backlog @desktop
    Scenario: Closing a terminal that is not active keeps the active one
      Given the thread has terminals 1, 2 and 3 with terminal 3 active
      When the user closes terminal 1
      Then terminal 3 is still active
      And its group and place in the row are unchanged

    @backlog @desktop
    Scenario: The terminal list names each group and how many terminals it holds
      Given the thread has one terminal on its own, a group of two side by side, and a stacked group of three
      When the user looks at the terminal list
      Then the groups are labelled "Single", "Side by side" and "Stacked"
      And each label shows how many terminals the group holds
      And choosing a group's label makes that group's terminal active

    @backlog @desktop
    Scenario: A single terminal shows its actions without a terminal list
      Given the thread has one terminal
      Then the terminal offers split, new and close actions over its own corner
      And no terminal list is shown
      When the user opens a second terminal
      Then the terminal list appears beside the terminals with the same actions

    @backlog @desktop
    Scenario: Clicking a terminal in a split makes it the active one
      Given the thread has two terminals side by side with the first active
      When the user clicks inside the second terminal
      Then the second terminal is active and has the keyboard
      And closing the active terminal now closes the second terminal

    @backlog @desktop
    Scenario: A terminal the user just closed does not come back from a late list
      Given the thread has terminals 1 and 2
      When the user closes terminal 1
      And the MC's list of terminals, sent before the close finished, still includes terminal 1
      Then terminal 1 does not return to the terminal list
      When terminal 1 is opened again later
      Then terminal 1 appears in the terminal list again

    @backlog @desktop
    Scenario: A new terminal is not dropped while the MC's list catches up
      Given the user opens a second terminal and the MC's list of terminals still shows only the first
      Then the second terminal stays in the terminal list
      And it stays in the split group it was opened in

    @desktop
    Scenario: Recently visited threads keep their terminals ready
      Given the user has visited ten threads with open terminals
      When the user returns to one of them
      Then its terminals show their live output without replaying history

    @backlog @mobile
    Scenario: The user switches between a thread's terminals on the phone
      Given a thread with two terminals
      When the user picks the second terminal on the phone
      Then the phone shows the second terminal's output

  Rule: The right panel holds terminal tabs of their own

    @desktop
    Scenario: A terminal tab runs its own terminal beside the drawer's
      Given the thread's terminal is open with one terminal
      When the user adds a terminal tab to the right panel
      Then the terminal tab runs a terminal of its own
      And the terminal drawer still shows only its first terminal

    @desktop
    Scenario: Closing a terminal tab stops its terminals
      Given the thread has a terminal tab in the right panel
      When the user closes the terminal tab
      Then the tab's terminal stops and its history is deleted

    @desktop
    Scenario Outline: The user splits a terminal tab
      Given the thread's terminal is open with one terminal
      And the thread has a terminal tab in the right panel
      When the user splits the terminal tab <direction>
      Then the terminal tab shows two terminals <placement>
      And the terminal drawer shows none of the tab's terminals

      Examples:
        | direction    | placement    |
        | horizontally | side by side |
        | vertically   | stacked      |
