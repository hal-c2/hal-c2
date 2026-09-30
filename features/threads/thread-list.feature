# Sources:
#   apps/desktop-qt/src/native/SidebarController.cpp (row actions, scope, parking, snooze menu, toasts)
#   apps/desktop-qt/src/native/SidebarModel.cpp (sections, project grouping and order)
#   apps/desktop-qt/src/native/ShellStore.cpp (the node's project and thread rows)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   packages/client-runtime/src/state/projectGrouping.ts (the grouping this ports)
#   apps/web/src/components/Sidebar.logic.ts (sortLogicalProjectsForSidebar, the order this ports)
#   apps/web/src/threadParking.ts (the navigation this ports)
#   threads/sidebar-list.feature, threads/settle.feature and threads/snooze.feature own what the
#   list and these actions mean; this file owns how the desktop runs them against its node.

Feature: The desktop's thread list against its node
  The desktop builds its thread list from the node's projects and threads, grouped and ordered
  by this device's settings, and sends the row actions (settle, snooze, wake, mark unread) to
  the node. Settling or snoozing the open thread moves on to the next one.

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
    And the node has the project "p1" titled "proj-1"
    And the node has the project "p2" titled "proj-2"
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

    @desktop
    Scenario: A scope whose project goes away shows everything again
      Given the user scopes the sidebar to "proj-2"
      When the node removes the project "p2"
      Then the sidebar is not scoped
      And the sidebar's "active" section lists "First, Second, Third"

    @desktop
    Scenario: Clearing the scope shows everything again
      Given the user scopes the sidebar to "proj-2"
      When the user clears the sidebar's scope
      Then the sidebar's "active" section lists "First, Second, Third"

  Rule: Projects are the node's, grouped and ordered on this device

    @desktop
    Scenario: Projects are listed by their latest thread
      Then the sidebar lists the projects "proj-1, proj-2"
      When the node updates the thread "t3" with:
        | latestUserMessageAt | 2026-09-23T09:55:00Z |
      Then the sidebar lists the projects "proj-2, proj-1"

    @desktop
    Scenario: Projects can be ordered by when their threads were started
      Given the node has these projects:
        | id | title  |
        | p3 | proj-3 |
      And the node updates the thread "t6" with:
        | projectId           | p3                   |
        | title               | Sixth                |
        | createdAt           | 2026-09-23T09:00:00Z |
        | updatedAt           | 2026-09-23T09:00:00Z |
        | latestUserMessageAt | 2026-09-23T09:58:00Z |
      And the sidebar lists the projects "proj-3, proj-1, proj-2"
      When this device's "sidebarProjectSortOrder" is set to "created_at"
      Then the sidebar lists the projects "proj-1, proj-2, proj-3"

    @desktop
    Scenario: Folders of one repository are one project
      Given the node has these projects:
        | id | title  | workspaceRoot  | repository             |
        | p3 | shop   | /work/shop     | github.com/acme/shop   |
        | p4 | shop-2 | /work/shop-2   | github.com/acme/shop   |
      Then the sidebar lists the projects "proj-1, proj-2, shop"

    @desktop
    Scenario: Folders of one repository stay apart when this device does not group them
      Given the node has these projects:
        | id | title  | workspaceRoot  | repository             |
        | p3 | shop   | /work/shop     | github.com/acme/shop   |
        | p4 | shop-2 | /work/shop-2   | github.com/acme/shop   |
      When this device's "sidebarProjectGroupingMode" is set to "separate"
      Then the sidebar lists the projects "proj-1, proj-2, shop, shop-2"

    @desktop
    Scenario: A project the node adds is listed
      When the node has these projects:
        | id | title  | createdAt            |
        | p3 | proj-3 | 2026-09-23T09:59:00Z |
      Then the sidebar lists the projects "proj-3, proj-1, proj-2"

    @desktop
    Scenario: A project the node removes is no longer listed
      When the node removes the project "p2"
      Then the sidebar lists the projects "proj-1"

  Rule: Row actions go to the node

    @desktop
    Scenario Outline: A row action sends its command to the node
      When the user <does> "env-a:t1"
      Then the node receives a "<command>" command for "t1"
      And the command's "<field>" is "<value>"

      Examples:
        | does           | command            | field | value |
        | un-settles     | thread.unsettle    | reason | user |
        | wakes          | thread.unsnooze    | reason | user |

    @desktop
    Scenario: Marking a thread unread sends it to the node
      When the user marks "env-a:t1" unread
      Then the node receives a "thread.mark-unread" command for "t1"

    @desktop
    Scenario: Settling a thread that is not open settles it without navigating
      Given the user is viewing "env-a:t2"
      When the user settles "env-a:t1"
      Then the node receives a "thread.settle" command for "t1"
      And the window shows the thread "env-a:t2"

    @desktop
    Scenario: A refused action shows why in a toast
      Given the node refuses "thread.unsettle" with "Thread is busy"
      When the user un-settles "env-a:t1"
      Then the user sees an "error" toast "Failed to un-settle thread" saying "Thread is busy"

  Rule: Parking the open thread moves to the next thread that stays in the list

    @desktop
    Scenario: Settling the open thread opens the next active thread
      Given the user is viewing "env-a:t1"
      When the user settles "env-a:t1"
      Then the window shows the thread "env-a:t2"

    @desktop
    Scenario: The next thread wraps around to the top
      Given the user is viewing "env-a:t3"
      When the user settles "env-a:t3"
      Then the window shows the thread "env-a:t1"

    @desktop
    Scenario: Settling the only thread left opens a new thread in its project
      Given the user scopes the sidebar to "proj-2"
      And the user is viewing "env-a:t3"
      When the user settles "env-a:t3"
      Then the window shows a new draft in "proj-2"

    @desktop
    Scenario: Moving elsewhere before the node answers keeps the user where they went
      Given the node holds its answers
      And the user is viewing "env-a:t1"
      When the user settles "env-a:t1"
      And the user opens "env-a:t3" from the sidebar
      And the node answers
      Then the window shows the thread "env-a:t3"

    @desktop
    Scenario: A refused settle stays on the open thread
      Given the node refuses "thread.settle" with "No"
      And the user is viewing "env-a:t1"
      When the user settles "env-a:t1"
      Then the user sees an "error" toast "Failed to settle thread" saying "No"
      And the window shows the thread "env-a:t1"

  Rule: Snoozing picks a time from a menu

    @desktop
    Scenario: The snooze menu offers the presets for now
      Given this device's "timestampFormat" is set to "24-hour"
      When the user opens the snooze menu for "env-a:t1" at 40, 120
      Then a menu opens at 40, 120 with:
        | id                | label                      |
        | snooze:hour       | In 1 hour (11:00)          |
        | snooze:three-hours | In 3 hours (13:00)        |
        | snooze:evening    | This evening (18:00)       |
        | snooze:tomorrow   | Tomorrow (09:00)           |
        | snooze:next-week  | Next week (Mon 09:00)      |

    @desktop
    Scenario: Picking a preset snoozes the thread and offers Undo
      Given this device's "timestampFormat" is set to "24-hour"
      And the user opens the snooze menu for "env-a:t1" at 40, 120
      When the user picks "snooze:hour"
      Then the menu closes
      And the node receives a "thread.snooze" command for "t1"
      And the command's "snoozedUntil" is "2026-09-23T11:00:00.000Z"
      And the user sees a "success" toast "Snoozed until 11:00" offering "Undo"

    @desktop
    Scenario: Undo from the toast wakes the thread
      Given this device's "timestampFormat" is set to "24-hour"
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
      Given the user is viewing "env-a:t1"
      And the user opens the snooze menu for "env-a:t1" at 0, 0
      When the user picks "snooze:tomorrow"
      Then the window shows the thread "env-a:t2"

  Rule: A woken thread's pill is dismissed by visiting up to the wake

    @desktop
    Scenario: Dismissing the woke pill marks the thread visited at its wake time
      Given the node updates the thread "t5" with:
        | snoozedUntil  | 2026-09-23T08:00:00Z |
        | lastVisitedAt | 2026-09-23T07:00:00Z |
      When the user dismisses the woke pill on "env-a:t5"
      Then the node receives a "thread.visit" command for "t5"
      And the command's "visitedAt" is "2026-09-23T08:00:00Z"
