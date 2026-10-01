# Sources:
#   apps/desktop-qt/src/native/ThreadMenuController.cpp (the thread menu, its actions, Undo, moving)
#   apps/desktop-qt/src/native/MenuController.cpp (the desktop's one menu and question)
#   apps/desktop-qt/src/native/KeybindingController.cpp (thread.pin, thread.settle, thread.copyReference, thread.undo)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (thread.menu), Workspace.qml (workspace.titleMenu)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   apps/web/src/components/threadActionMenu.logic.ts (the order this ports)
#   apps/web/src/hooks/useThreadActions.ts (archive, delete, unpin and their confirmations)
#   apps/server-ex/lib/hal_c2/mcp/tools/threads.ex (hal-c2.moveDestinations, hal-c2.moveThread answers)
#   threads/menu-and-selection.feature, threads/archive-delete.feature, threads/pinning-and-order.feature
#   (Undoing a thread change) and threads/moving-between-machines.feature own what these actions
#   mean; this file owns how the desktop's menu runs them against the MC.

Feature: Running a thread's actions from its menu
  A thread's menu, from its row in the sidebar or the header's title, sends each action to
  the MC, reports what the MC refuses, and offers the way back for the actions that take
  a thread out of view.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title  | branch     | createdAt            |
      | t1 | p1      | First  | feat/first | 2026-09-23T09:50:00Z |
      | t2 | p1      | Second |            | 2026-09-23T09:40:00Z |
    And the MC has the project "p1" titled "proj-1"
    And the desktop shell is connected to its MC

  Rule: What the menu offers

    @desktop
    Scenario: A thread's menu lists what can be done to it
      When the user opens the thread menu for "env-a:t1" at 40, 120
      Then a menu opens at 40, 120 with:
        | id                   | label                 |
        | new-thread-on-branch | New thread on feat/first |
        | pin                  | Pin thread            |
        | settle               | Settle thread         |
        | snooze               | Snooze                |
        | rename               | Rename thread         |
        | regenerate-title     | Regenerate title      |
        | mark-unread          | Mark unread           |
        | filter-by-project    | Filter by proj-1      |
        | copy                 | Copy                  |
        | project-settings     | Project settings      |
        | fork                 | Fork thread           |
        | archive              | Archive thread        |
        | delete               | Delete                |

    @desktop
    Scenario: The header's title opens the open thread's menu without the project filter
      Given the user is viewing "env-a:t2"
      When the user opens the header's title menu at 10, 20
      Then the menu offers "archive"
      And the menu does not offer "filter-by-project"

    @desktop
    Scenario: A thread on an offline environment offers only what needs no environment
      Given the environment "env-b" is offline
      When the user opens the thread menu for "env-b:t-linked" at 40, 120
      Then only these of the menu's actions can be chosen: "copy"

    @desktop
    Scenario: Moving is offered once another machine of the cluster can take the thread
      Given the MC is clustered with "mc-b", which serves "env-b"
      When the user opens the thread menu for "env-a:t1" at 40, 120
      Then the menu offers "move"

  Rule: Each action reports a refusal

    @desktop
    Scenario Outline: A refused action is reported
      Given the MC refuses "<command>" with "Not now"
      And the user opens the thread menu for "env-a:t1" at 40, 120
      When the user picks "<item>"
      Then the user sees an "error" toast "<message>" saying "Not now"

      Examples:
        | item             | command                | message                          |
        | pin              | thread.pin             | Failed to pin thread             |
        | archive          | thread.archive         | Failed to archive thread         |
        | regenerate-title | thread.metadata.update | Failed to regenerate thread title |
        | fork             | thread.fork            | Failed to fork thread            |

  Rule: What takes a thread out of view can be undone
    # Undoing an archive, unpin, settle or snooze is threads/pinning-and-order.feature's
    # "Undoing a thread change".

    @desktop
    Scenario: The undo shortcut runs the newest Undo on offer
      Given the user opens the thread menu for "env-a:t2" at 40, 120
      And the user picks "archive"
      And the MC receives a "thread.archive" command for "t2"
      And the user sees a "success" toast "Archived" offering "Undo"
      When the user presses mod+z
      Then the MC receives a "thread.unarchive" command for "t2"

  Rule: Deleting asks first

    @desktop
    Scenario: Cancelling the question keeps the thread
      Given the user opens the thread menu for "env-a:t2" at 40, 120
      And the user picks "delete"
      When the user cancels the question
      Then the MC receives no commands

    @desktop
    Scenario: Confirming the question deletes the thread
      Given the user opens the thread menu for "env-a:t2" at 40, 120
      And the user picks "delete"
      When the user confirms the question
      Then the MC receives a "thread.delete" command for "t2"

  Rule: The other actions

    @desktop
    Scenario: Forking opens the fork
      Given the user opens the thread menu for "env-a:t1" at 40, 120
      When the user picks "fork"
      Then the MC is asked to fork "t1"
      And the window shows the fork

    @desktop
    Scenario: Renaming from the menu opens the thread and starts the header's rename
      Given the user opens the thread menu for "env-a:t2" at 40, 120
      When the user picks "rename"
      Then the header is renaming "Second"

    @desktop
    Scenario: The pin shortcut pins and unpins the open thread
      Given the user is viewing "env-a:t1"
      When the user presses mod+shift+p
      Then the MC receives a "thread.pin" command for "t1"

    @desktop
    Scenario: The copy shortcut copies the open thread's id
      Given the user is viewing "env-a:t1"
      When the user presses mod+shift+c
      Then the clipboard holds "t1"
      And the user sees a "success" toast "Thread ID copied" saying "t1"

  Rule: Moving to another machine

    Background:
      Given the MC is clustered with "mc-b", which serves "env-b"

    @desktop
    Scenario: Machines are offered as the MC lists them, offline ones disabled
      Given the MC can move "t1" to "mc-b" and to "mc-c", which is offline
      And the user opens the thread menu for "env-a:t1" at 40, 120
      When the user picks "move"
      Then a menu opens at 40, 120 with:
        | id           | label          |
        | machine:mc-b | mc-b           |
        | machine:mc-c | mc-c (offline) |
      And only these of the menu's actions can be chosen: "machine:mc-b"

    @desktop
    Scenario: Moving the open thread follows it to its new machine
      Given the MC can move "t1" to "mc-b"
      And the user is viewing "env-a:t1"
      And the user opens the thread menu for "env-a:t1" at 40, 120
      And the user picks "move"
      When the user picks "machine:mc-b"
      Then the MC is asked to move "t1" to "mc-b"
      And the user sees a "success" toast "First moved to mc-b."
      And the window shows the thread "env-b:t1"

    @desktop
    Scenario: A move that leaves something behind asks first
      Given the MC can move "t1" to "mc-b" once told "Its terminal stays behind."
      And the user opens the thread menu for "env-a:t1" at 40, 120
      And the user picks "move"
      And the user picks "machine:mc-b"
      When the user confirms the question
      Then the MC is asked to move "t1" to "mc-b" confirmed

    @desktop
    Scenario: A refused move is reported
      Given the MC can move "t1" to "mc-b" but refuses with "mc-b has no checkout of shop"
      And the user opens the thread menu for "env-a:t1" at 40, 120
      And the user picks "move"
      When the user picks "machine:mc-b"
      Then the user sees an "error" toast "Failed to move thread" saying "mc-b has no checkout of shop"
