# Sources:
#   apps/desktop-qt/src/TerminalController.cpp (the drawer's tabs, sessions and RPCs against the node)
#   apps/desktop-qt/src/NativeShell.cpp (lends the node the page's access to environments)
#   apps/web/src/shell/useShellEnvironmentAccess.ts (the page's access to its saved environments)
#   apps/web/src/shell/shellWorkspaceState.ts (the thread, drafts too, its project root, worktree
#   and scripts, which the drawer takes from the page)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalDrawer.qml (qml-ghostty's Terminal per tab)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/ThreadTerminals.tsx (the launch context and script runs this mirrors)
#   packages/shared/src/terminalLabels.ts (terminal ids and tab labels)
#   Shared domain: terminal/ owns what a thread's terminals do; connections/links.feature owns
#   how the node reaches an environment outside its cluster; this file owns that the Qt shell
#   runs its drawer against the node itself.

Feature: The desktop shell runs the terminal drawer against its node
  The Qt shell draws a thread's terminals with qml-ghostty and talks to the node for them
  itself: it attaches each terminal, sends what the user types and shows what the shell
  prints. From the page it takes only which thread is shown and that thread's project root,
  worktree and scripts, as its header shows them.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"
    And the node has the project "p1" at "/work/p1"
    And the project "p1" has these scripts:
      | id   | name | command  |
      | test | Test | bun test |
    And the node has these threads:
      | id | project | title | worktreePath |
      | t1 | p1      | One   |              |
      | t2 | p1      | Two   | /work/p1-wt  |
      | t3 | p9      | Lost  |              |
    And the desktop shell is connected to its node
    And the page shows "env-a:t1"

  Rule: The drawer opens on the thread's own terminals

    @desktop
    Scenario: Opening the drawer starts the thread's first terminal in its project
      When the user toggles the terminal drawer
      Then the terminal drawer shows the tabs "Terminal 1"
      And the node attaches "term-1" of "t1" in "/work/p1"
      And "term-1" of "t1" starts with "HAL_C2_PROJECT_ROOT" set to "/work/p1"
      And nothing reaches the page

    @desktop
    Scenario: A worktree thread's terminal starts in its worktree
      Given the page shows "env-a:t2"
      When the user toggles the terminal drawer
      Then the node attaches "term-1" of "t2" in "/work/p1-wt"
      And "term-1" of "t2" starts with "HAL_C2_WORKTREE_PATH" set to "/work/p1-wt"

    @desktop
    Scenario: A thread whose project the node does not know has no terminal
      Given the page shows "env-a:t3"
      Then the terminal drawer is unavailable

    @desktop
    Scenario: A draft thread has a terminal in its project
      Given the page shows the draft "d1" in "p1"
      When the user toggles the terminal drawer
      Then the terminal drawer shows the tabs "Terminal 1"
      And the node attaches "term-1" of "d1" in "/work/p1"

    @desktop
    Scenario: A thread on a node clustered with the desktop's node has its terminal there
      Given the node is clustered with "node-b", which serves "env-b"
      And the page shows "env-b:t9" with its project at "/work/p9"
      When the user toggles the terminal drawer
      Then "env-b" attaches "term-1" of "t9" in "/work/p9"

    @desktop
    Scenario: A thread on an environment the node is linked to has its terminal there
      Given the node is linked to "env-c"
      And the page shows "env-c:t7" with its project at "/work/p7"
      When the user toggles the terminal drawer
      Then "env-c" attaches "term-1" of "t7" in "/work/p7"

    @desktop
    Scenario: A thread on an environment the page has access to has its terminal there
      Given the page has access to "env-c"
      And the page shows "env-c:t7" with its project at "/work/p7"
      When the user toggles the terminal drawer
      Then "env-c" attaches "term-1" of "t7" in "/work/p7"

    @desktop
    Scenario: The node keeps the page's access while the page is disconnected there
      Given the page has access to "env-c"
      When the page loses its connection to "env-c"
      Then the node is linked to "env-c" with the page's access

    @desktop
    Scenario: The node gives back the page's access when the page forgets the environment
      Given the page has access to "env-c"
      When the page forgets "env-c"
      Then the node is not linked to "env-c"

    @desktop
    Scenario: A thread on an environment the node does not reach has no terminal
      Given the page shows "env-x:t8" with its project at "/work/p8"
      Then the terminal drawer is unavailable

    @desktop
    Scenario: The drawer shows the terminals the thread already has
      Given the node runs these terminals for "t1":
        | terminal | label      |
        | term-2   | dev server |
      When the user toggles the terminal drawer
      Then the terminal drawer shows the tabs "dev server"
      And the node is not asked to open a terminal

    @desktop
    Scenario: Hiding the drawer keeps its terminals running and attached
      When the user toggles the terminal drawer
      And the user toggles the terminal drawer
      Then the terminal drawer is closed
      And "term-1" of "t1" is still attached

  Rule: Each terminal is a tab

    @desktop
    Scenario: A new terminal takes the lowest free number
      Given the node runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-3   |
      When the user toggles the terminal drawer
      And the user opens a new terminal
      Then the terminal drawer shows the tabs "Terminal 1, Terminal 2, Terminal 3"
      And the active terminal is "term-2"

    @desktop
    Scenario: A thread has at most six terminals
      Given the node runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-2   |
        | term-3   |
        | term-4   |
        | term-5   |
        | term-6   |
      When the user toggles the terminal drawer
      And the user opens a new terminal
      Then the user sees an "error" toast "At most 6 terminals per thread."
      And the terminal drawer shows the tabs "Terminal 1, Terminal 2, Terminal 3, Terminal 4, Terminal 5, Terminal 6"

    @desktop
    Scenario: Closing the active terminal ends it and selects the last one left
      Given the node runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-2   |
        | term-3   |
      When the user toggles the terminal drawer
      And the user selects "term-2"
      And the user closes the active terminal
      Then the node is asked to close "term-2" of "t1" and delete its history
      And the terminal drawer shows the tabs "Terminal 1, Terminal 3"
      And the active terminal is "term-3"

    @desktop
    Scenario: Closing the last terminal hides the drawer
      When the user toggles the terminal drawer
      And the user closes the active terminal
      Then the node is asked to close "term-1" of "t1" and delete its history
      And the terminal drawer is closed

    @desktop
    Scenario: A terminal closed from another client leaves the drawer
      Given the node runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-2   |
      When the user toggles the terminal drawer
      And the node closes "term-2" of "t1"
      Then the terminal drawer shows the tabs "Terminal 1"

  Rule: What the shell prints and what the user types go through the node

    @desktop
    Scenario: Output reaches the terminal
      When the user toggles the terminal drawer
      And the node prints "hello\r\n" in "term-1" of "t1"
      Then "term-1" shows "hello"

    @desktop
    Scenario: Keys typed while a write is on its way follow it in one write
      Given the user toggles the terminal drawer
      And the node attaches "term-1" of "t1" in "/work/p1"
      And the node holds its answers
      When the user types "l" in "term-1"
      And the user types "s" in "term-1"
      And the user types "\r" in "term-1"
      Then the node receives these writes to "term-1":
        | data |
        | l    |
      When the node answers
      Then the node receives these writes to "term-1":
        | data |
        | l    |
        | s\r  |

  Rule: Project scripts run in the drawer

    @desktop
    Scenario: A script runs in the active terminal and opens the drawer
      When the user runs the script "test"
      Then the terminal drawer shows the tabs "Terminal 1"
      And the node is asked to open "term-1" of "t1" in "/work/p1"
      And the node receives these writes to "term-1":
        | data         |
        | bun test\r   |

    @desktop
    Scenario: A script runs in a new terminal when the active one is busy
      Given the node runs these terminals for "t1":
        | terminal | busy |
        | term-1   | yes  |
      When the user runs the script "test"
      Then the node is asked to open "term-2" of "t1" in "/work/p1"
      And the node receives these writes to "term-2":
        | data       |
        | bun test\r |
      And the terminal drawer shows the tabs "Terminal 1, Terminal 2"

  Rule: What the page's drawer did that the native drawer does not yet

    @backlog @desktop
    Scenario: The drawer follows the user's own terminal chords
      Given the user bound "terminal.toggle" to "mod+shift+t"
      When the user presses "mod+shift+t"
      Then the terminal drawer opens

    @backlog @desktop
    Scenario: The drawer's height and open terminals survive a restart
      Given the user dragged the drawer to 400 pixels with "term-2" active
      When the desktop starts again
      Then the drawer is 400 pixels tall with "term-2" active
