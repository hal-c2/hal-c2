# Sources:
#   apps/desktop-qt/src/native/DraftController.cpp (the shell's drafts: start, open, delete, promote, keep)
#   apps/desktop-qt/src/native/ComposerController.cpp (a draft's first send promotes it)
#   apps/desktop-qt/src/native/NavigationController.cpp (the page follows a draft with its thread id)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (draft rows and their menu)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/shell/HalC2ShellBridge.tsx (opens the shell's draft as its composer draft)
#   Shared domain: threads/creating.feature owns what a new thread is; this file owns that the
#   Qt shell keeps the drafts itself.

Feature: The desktop shell keeps its own drafts
  A new thread is a draft until its first message is sent. The Qt shell keeps its drafts on
  this machine, one per project folder, lists them at the top of the sidebar and opens them
  itself; the page draws the draft's composer for the thread id the draft will become. The
  draft's text is kept with the draft.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title  | createdAt            |
      | t1 | p1      | First  | 2026-09-23T09:50:00Z |
      | t3 | p2      | Third  | 2026-09-23T09:30:00Z |
    And the node has the project "p1" titled "proj-1"
    And the node has the project "p2" titled "proj-2"
    And the desktop shell is connected to its node

  Rule: A new thread opens its project's draft

    @desktop
    Scenario: A new thread without a project starts where the window is
      Given the user opens "env-a:t3" from the sidebar
      When the user starts a new thread
      Then the window shows a new draft in "proj-2"

    @desktop
    Scenario: Starting a new thread again reopens the same draft
      Given the user starts a new thread in "proj-1"
      And the user opens "env-a:t1" from the sidebar
      When the user starts a new thread in "proj-1"
      Then the window shows the draft
      And the shell keeps 1 draft

    @desktop
    Scenario: A project that is gone starts nothing
      When the user starts a new thread in "proj-9"
      Then the shell keeps 0 drafts
      And the page is not told where to go

  Rule: A draft ends when it is sent or deleted

    @desktop
    Scenario: The draft becomes its thread when the node creates it
      Given the user starts a new thread in "proj-1"
      When the node creates the draft's thread
      Then the window shows the draft's thread
      And the sidebar lists no drafts

    @desktop
    Scenario: The draft's menu offers to delete it
      Given the user starts a new thread in "proj-1"
      When the user opens the draft's menu at 30, 60
      Then the shell shows a menu at 30, 60 with:
        | id     | label        |
        | delete | Delete draft |

    @desktop
    Scenario: Deleting the open draft leaves it
      Given the user starts a new thread in "proj-1"
      And the user opens the draft's menu at 30, 60
      When the user picks "delete"
      Then the menu closes
      And the sidebar lists no drafts
      And the window shows home

    @desktop
    Scenario: Dismissing the draft's menu keeps the draft
      Given the user starts a new thread in "proj-1"
      And the user opens the draft's menu at 30, 60
      When the user dismisses the menu
      Then the menu closes
      And the sidebar lists the draft

    @desktop
    Scenario: A draft whose project the node removes goes with it
      Given the user starts a new thread in "proj-1"
      When the node removes the project "p1"
      Then the sidebar lists no drafts
      And the window shows home

  Rule: Drafts stay on this machine

    @desktop
    Scenario: Drafts are still there after a restart
      Given the user starts a new thread in "proj-1"
      When the desktop quits and starts again
      And the desktop shell is connected to its node
      Then the sidebar lists the draft
      And the window shows the draft
