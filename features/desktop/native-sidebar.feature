# Sources:
#   apps/desktop-qt/src/native/SidebarController.cpp (row actions, scope, parking, snooze menu, toasts)
#   apps/desktop-qt/src/native/SidebarModel.cpp (the port of the page's sidebar rules)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/shell/HalC2ShellBridge.tsx (publishes sidebarInput)
#   apps/web/src/threadParking.ts (the navigation this ports)
#   Shared domain: threads/settle.feature, threads/snooze.feature and threads/sidebar-list.feature
#   own what these actions mean; this file owns that the Qt shell sends them itself.

Feature: The desktop shell runs the sidebar against its node
  Once connected, the Qt shell builds the sidebar from the node's threads and the page's project
  groups, and sends the row actions (settle, snooze, wake, mark unread) to the node itself.
  Toasts are the shell's own; navigation still renders in the page, so the shell asks the page for it.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title  | createdAt            | settledOverride | snoozedUntil         |
      | t1 | p1      | First  | 2026-09-23T09:50:00Z |                 |                      |
      | t2 | p1      | Second | 2026-09-23T09:40:00Z |                 |                      |
      | t3 | p2      | Third  | 2026-09-23T09:30:00Z |                 |                      |
      | t4 | p1      | Done   | 2026-09-23T09:20:00Z | settled         |                      |
      | t5 | p2      | Later  | 2026-09-23T09:10:00Z |                 | 2026-09-24T09:00:00Z |
    And the page groups "env-a:p1" as the project "proj-1"
    And the page groups "env-a:p2" as the project "proj-2"
    And the desktop shell is connected to its node

  Rule: The sidebar is built from the node's threads

    @desktop
    Scenario: Threads land in their sections
      Then the sidebar's "active" section lists "First, Second, Third"
      And the sidebar's "settled" section lists "Done"
      And the sidebar's "snoozed" section lists "Later"

    @desktop
    Scenario: Scoping to a project shows only its threads
      When the user scopes the sidebar to "proj-2"
      Then the sidebar's "active" section lists "Third"
      And the sidebar's "snoozed" section lists "Later"
      And the page is told the sidebar is scoped to "proj-2"

    @desktop
    Scenario: A scope whose project goes away shows everything again
      Given the user scopes the sidebar to "proj-2"
      When the page stops grouping "env-a:p2"
      Then the sidebar is not scoped
      And the sidebar's "active" section lists "First, Second, Third"

    @desktop
    Scenario: Clearing the scope shows everything again
      Given the user scopes the sidebar to "proj-2"
      When the user clears the sidebar's scope
      Then the sidebar's "active" section lists "First, Second, Third"

  Rule: Row actions go to the node

    @desktop
    Scenario Outline: A row action sends its command to the node
      When the user <does> "env-a:t1"
      Then the node receives a "<command>" command for "t1"
      And the command's "<field>" is "<value>"
      And nothing reaches the page

      Examples:
        | does           | command            | field | value |
        | un-settles     | thread.unsettle    | reason | user |
        | wakes          | thread.unsnooze    | reason | user |

    @desktop
    Scenario: Marking a thread unread sends it to the node
      When the user marks "env-a:t1" unread
      Then the node receives a "thread.mark-unread" command for "t1"

    @desktop
    Scenario Outline: An environment that does not track visits keeps unread markers in the page
      Given the node's environment does not track visits
      And the node sends its snapshot
      When the user dispatches "<action>" for "env-a:t1"
      Then the action "<action>" for "env-a:t1" reaches the page
      And the node receives no commands

      Examples:
        | action             |
        | thread.markUnread  |
        | thread.wokeDismiss |

    @desktop
    Scenario: Settling a thread that is not open settles it without navigating
      Given the page shows "env-a:t2"
      When the user settles "env-a:t1"
      Then the node receives a "thread.settle" command for "t1"
      And nothing reaches the page

    @desktop
    Scenario: A refused action shows why in a toast
      Given the node refuses "thread.unsettle" with "Thread is busy"
      When the user un-settles "env-a:t1"
      Then the user sees an "error" toast "Failed to un-settle thread" saying "Thread is busy"

    @desktop
    Scenario: A thread the node's cluster does not know stays with the page
      When the user settles "env-b:elsewhere"
      Then the action "thread.settle" for "env-b:elsewhere" reaches the page
      And the node receives no commands

  Rule: Parking the open thread moves to the next thread that stays in the list

    @desktop
    Scenario: Settling the open thread opens the next active thread
      Given the page shows "env-a:t1"
      When the user settles "env-a:t1"
      Then the page is asked to open "env-a:t2"

    @desktop
    Scenario: The next thread wraps around to the top
      Given the page shows "env-a:t3"
      When the user settles "env-a:t3"
      Then the page is asked to open "env-a:t1"

    @desktop
    Scenario: Settling the only thread left opens a new thread in its project
      Given the user scopes the sidebar to "proj-2"
      And the page shows "env-a:t3"
      When the user settles "env-a:t3"
      Then the page is asked to open a new thread in "proj-2"

    @desktop
    Scenario: Moving elsewhere before the node answers keeps the user where they went
      Given the node holds its answers
      And the page shows "env-a:t1"
      When the user settles "env-a:t1"
      And the page shows "env-a:t3"
      And the node answers
      Then nothing reaches the page

    @desktop
    Scenario: A refused settle stays on the open thread
      Given the node refuses "thread.settle" with "No"
      And the page shows "env-a:t1"
      When the user settles "env-a:t1"
      Then the user sees an "error" toast "Failed to settle thread" saying "No"
      And the page is not asked to open anything

  Rule: Snoozing picks a time from the shell's menu

    @desktop
    Scenario: The snooze menu offers the presets for now
      Given the page's timestamps are "24-hour"
      When the user opens the snooze menu for "env-a:t1" at 40, 120
      Then the shell shows a menu at 40, 120 with:
        | id                | label                      |
        | snooze:hour       | In 1 hour (11:00)          |
        | snooze:three-hours | In 3 hours (13:00)        |
        | snooze:evening    | This evening (18:00)       |
        | snooze:tomorrow   | Tomorrow (09:00)           |
        | snooze:next-week  | Next week (Mon 09:00)      |

    @desktop
    Scenario: Picking a preset snoozes the thread and offers Undo
      Given the page's timestamps are "24-hour"
      And the user opens the snooze menu for "env-a:t1" at 40, 120
      When the user picks "snooze:hour"
      Then the menu closes
      And the node receives a "thread.snooze" command for "t1"
      And the command's "snoozedUntil" is "2026-09-23T11:00:00.000Z"
      And the user sees a "success" toast "Snoozed until 11:00" offering "Undo"

    @desktop
    Scenario: Undo from the toast wakes the thread
      Given the page's timestamps are "24-hour"
      And the user opens the snooze menu for "env-a:t1" at 40, 120
      And the user picks "snooze:hour"
      And the node receives a "thread.snooze" command for "t1"
      When the user chooses "Undo" on the toast "Snoozed until 11:00"
      Then the node receives a "thread.unsnooze" command for "t1"
      And the toast "Snoozed until 11:00" is gone

    @desktop
    Scenario: Dismissing the menu snoozes nothing
      Given the user opens the snooze menu for "env-a:t1" at 40, 120
      When the user dismisses the menu
      Then the menu closes
      And the node receives no commands

    @desktop
    Scenario: Snoozing the open thread opens the next one
      Given the page shows "env-a:t1"
      And the user opens the snooze menu for "env-a:t1" at 0, 0
      When the user picks "snooze:tomorrow"
      Then the page is asked to open "env-a:t2"

  Rule: A woken thread's pill is dismissed by visiting up to the wake

    @desktop
    Scenario: Dismissing the woke pill marks the thread visited at its wake time
      Given the node updates the thread "t5" with:
        | snoozedUntil  | 2026-09-23T08:00:00Z |
        | lastVisitedAt | 2026-09-23T07:00:00Z |
      When the user dismisses the woke pill on "env-a:t5"
      Then the node receives a "thread.visit" command for "t5"
      And the command's "visitedAt" is "2026-09-23T08:00:00Z"
