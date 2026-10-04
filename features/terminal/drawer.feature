# Sources:
#   apps/desktop-qt/src/TerminalController.cpp (the drawer's tabs, sessions and RPCs against the MC)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the route's thread, drafts too, its project
#   root, worktree and scripts, from the MC's rows)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalDrawer.qml (qml-ghostty's Terminal per tab)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   apps/web/src/components/ThreadTerminals.tsx (the launch context and script runs this mirrors)
#   packages/shared/src/terminalLabels.ts (terminal ids and tab labels)
#   terminal/sessions.feature and terminal/tabs.feature own what a thread's terminals do;
#   connections/links.feature owns how the MC reaches an environment outside its cluster.

Feature: The desktop's terminal drawer
  The desktop draws a thread's terminals with qml-ghostty and talks to the MC for them: it
  attaches each terminal, sends what the user types and shows what the shell prints. The
  thread is the one on screen, and its project root, worktree and scripts are the MC's rows
  for it, as the workspace header shows them.

  Background:
    Given the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has the project "p1" at "/work/p1"
    And the project "p1" has these scripts:
      | id   | name | command  |
      | test | Test | bun test |
    And the MC has these threads:
      | id | project | title | worktreePath |
      | t1 | p1      | One   |              |
      | t2 | p1      | Two   | /work/p1-wt  |
      | t3 | p9      | Lost  |              |
    And the desktop shell is connected to its MC
    And the user is viewing "env-a:t1"

  Rule: The drawer opens on the thread's own terminals

    @desktop
    Scenario: Opening the drawer starts the thread's first terminal in its project
      When the user toggles the terminal drawer
      Then the terminal drawer shows the tabs "Terminal 1"
      And the MC attaches "term-1" of "t1" in "/work/p1"
      And "term-1" of "t1" starts with "HAL_C2_PROJECT_ROOT" set to "/work/p1"

    @desktop
    Scenario: A worktree thread's terminal starts in its worktree
      Given the user is viewing "env-a:t2"
      When the user toggles the terminal drawer
      Then the MC attaches "term-1" of "t2" in "/work/p1-wt"
      And "term-1" of "t2" starts with "HAL_C2_WORKTREE_PATH" set to "/work/p1-wt"

    @desktop
    Scenario: A thread whose project the MC does not know has no terminal
      Given the user is viewing "env-a:t3"
      Then the terminal drawer is unavailable

    @desktop
    Scenario: A draft thread has a terminal in its project
      Given the user is viewing a new thread in "p1"
      When the user toggles the terminal drawer
      Then the terminal drawer shows the tabs "Terminal 1"
      And the MC attaches "term-1" of the new thread in "/work/p1"

    @desktop
    Scenario: A thread on an MC clustered with the desktop's MC has its terminal there
      Given the MC is clustered with "mc-b", which serves "env-b"
      And the user is viewing "env-b:t9" with its project at "/work/p9"
      When the user toggles the terminal drawer
      Then "env-b" attaches "term-1" of "t9" in "/work/p9"

    @desktop
    Scenario: A thread on an environment the MC is linked to has its terminal there
      Given the MC is linked to "env-c"
      And the user is viewing "env-c:t7" with its project at "/work/p7"
      When the user toggles the terminal drawer
      Then "env-c" attaches "term-1" of "t7" in "/work/p7"

    @desktop
    Scenario: A thread on an environment the MC does not reach has no terminal
      Given the user is viewing "env-x:t8" with its project at "/work/p8"
      Then the terminal drawer is unavailable

    @desktop
    Scenario: The drawer shows the terminals the thread already has
      Given the MC runs these terminals for "t1":
        | terminal | label      |
        | term-2   | dev server |
      When the user toggles the terminal drawer
      Then the terminal drawer shows the tabs "dev server"
      And the MC is not asked to open a terminal

    @desktop
    Scenario: Hiding the drawer keeps its terminals running and attached
      When the user toggles the terminal drawer
      And the user toggles the terminal drawer
      Then the terminal drawer is closed
      And "term-1" of "t1" is still attached

  Rule: Each terminal is a tab

    @desktop
    Scenario: A new terminal takes the lowest free number
      Given the MC runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-3   |
      When the user toggles the terminal drawer
      And the user opens a new terminal
      Then the terminal drawer shows the tabs "Terminal 1, Terminal 2, Terminal 3"
      And the active terminal is "term-2"

    @desktop
    Scenario: A thread has at most six terminals
      Given the MC runs these terminals for "t1":
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
      Given the MC runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-2   |
        | term-3   |
      When the user toggles the terminal drawer
      And the user selects "term-2"
      And the user closes the active terminal
      Then the MC is asked to close "term-2" of "t1" and delete its history
      And the terminal drawer shows the tabs "Terminal 1, Terminal 3"
      And the active terminal is "term-3"

    @desktop
    Scenario: Closing the last terminal hides the drawer
      When the user toggles the terminal drawer
      And the user closes the active terminal
      Then the MC is asked to close "term-1" of "t1" and delete its history
      And the terminal drawer is closed

    @desktop
    Scenario: A terminal closed from another client leaves the drawer
      Given the MC runs these terminals for "t1":
        | terminal |
        | term-1   |
        | term-2   |
      When the user toggles the terminal drawer
      And the MC closes "term-2" of "t1"
      Then the terminal drawer shows the tabs "Terminal 1"

  Rule: What the terminal prints and what the user types go through the MC

    @desktop
    Scenario: Output reaches the terminal
      When the user toggles the terminal drawer
      And the MC prints "hello\r\n" in "term-1" of "t1"
      Then "term-1" shows "hello"

    @desktop
    Scenario: Keys typed while a write is on its way follow it in one write
      Given the user toggles the terminal drawer
      And the MC attaches "term-1" of "t1" in "/work/p1"
      And the MC holds its answers
      When the user types "l" in "term-1"
      And the user types "s" in "term-1"
      And the user types "\r" in "term-1"
      Then the MC receives these writes to "term-1":
        | data |
        | l    |
      When the MC answers
      Then the MC receives these writes to "term-1":
        | data |
        | l    |
        | s\r  |

  Rule: Project scripts run in the drawer

    @desktop
    Scenario: A script runs in the active terminal and opens the drawer
      When the user runs the script "test"
      Then the terminal drawer shows the tabs "Terminal 1"
      And the MC is asked to open "term-1" of "t1" in "/work/p1"
      And the MC receives these writes to "term-1":
        | data         |
        | bun test\r   |

    @desktop
    Scenario: A script runs in a new terminal when the active one is busy
      Given the MC runs these terminals for "t1":
        | terminal | busy |
        | term-1   | yes  |
      When the user runs the script "test"
      Then the MC is asked to open "term-2" of "t1" in "/work/p1"
      And the MC receives these writes to "term-2":
        | data       |
        | bun test\r |
      And the terminal drawer shows the tabs "Terminal 1, Terminal 2"

  Rule: Not on the desktop yet

    @desktop
    Scenario: The drawer follows the user's own terminal chords
      Given the user bound "terminal.toggle" to "mod+shift+t"
      When the user presses "mod+shift+t"
      Then the terminal drawer opens

    @desktop
    Scenario: The drawer's height and open terminals survive a restart
      Given the user dragged the drawer to 400 pixels with "term-2" active
      When the desktop starts again
      Then the drawer is 400 pixels tall with "term-2" active
