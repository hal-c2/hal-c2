# Sources:
#   apps/desktop-qt/src/native/SidebarController.cpp (what it leaves to the page)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   threads/thread-list.feature has what the desktop's sidebar does against its node; this file
#   keeps what it still leaves to the embedded page.

Feature: What the desktop's sidebar leaves to the page
  The desktop sends row actions to its node itself. What its node cannot take, the page keeps.

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

  Rule: What the node cannot take stays with the page

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
    Scenario: A thread the node's cluster does not know stays with the page
      When the user settles "env-b:elsewhere"
      Then the action "thread.settle" for "env-b:elsewhere" reaches the page
      And the node receives no commands
