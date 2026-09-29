# Sources:
#   apps/desktop-qt/src/native/DraftController.cpp (the desktop's drafts: start, open, delete, promote, keep)
#   apps/desktop-qt/src/native/ComposerController.cpp (a draft's first send promotes it)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (draft rows and their menu)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   navigation/landing.feature owns the draft a window with no thread lands on, which is here
#   from the start: the window opens on a draft in "proj-1".
#   threads/creating.feature owns what a new thread is; this file owns how the desktop keeps
#   its drafts.

Feature: Drafts on the desktop
  A new thread is a draft until its first message is sent. The desktop keeps its drafts on
  this machine, one per project folder, lists them at the top of the sidebar and opens them.
  The draft's text is kept with the draft.

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
    Scenario: Starting a new thread again reopens the same draft
      Given the user starts a new thread in "proj-1"
      And the user opens "env-a:t1" from the sidebar
      When the user starts a new thread in "proj-1"
      Then the window shows the draft
      And the desktop keeps 1 draft

    @desktop
    Scenario: A project that is gone starts nothing
      When the user starts a new thread in "proj-9"
      Then the window shows a new draft in "proj-1"
      And the desktop keeps 1 draft

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
      Then a menu opens at 30, 60 with:
        | id     | label        |
        | delete | Delete draft |

    @desktop
    Scenario: Deleting the open draft lands on a new thread
      Given the user starts a new thread in "proj-2"
      And the user opens the draft's menu at 30, 60
      When the user picks "delete"
      Then the menu closes
      And the window shows a new draft in "proj-1"
      And the desktop keeps 1 draft

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
      Then the window shows a new draft in "proj-2"
      And the desktop keeps 1 draft

  Rule: Drafts stay on this machine

    @desktop
    Scenario: Drafts are still there after a restart
      Given the user starts a new thread in "proj-1"
      When the desktop quits and starts again
      And the desktop shell is connected to its node
      Then the sidebar lists the draft
      And the window shows the draft
