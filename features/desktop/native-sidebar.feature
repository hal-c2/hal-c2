# Sources:
#   apps/desktop-qt/src/native/SidebarController.cpp (the row actions it does not send)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   threads/thread-list.feature has what the desktop's sidebar does against its node; this file
#   keeps what it does not send.

Feature: What the desktop's sidebar does not send to its node
  The desktop sends row actions to its node itself. What its node cannot take, it does not send.

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

  Rule: What the node cannot take is not sent

    @desktop
    Scenario Outline: An environment that does not track visits is sent no unread markers
      Given the node's environment does not track visits
      And the node sends its snapshot
      When the user dispatches "<action>" for "env-a:t1"
      Then the node receives no commands

      Examples:
        | action             |
        | thread.markUnread  |
        | thread.wokeDismiss |

    @desktop
    Scenario: A thread the node's cluster does not know is not sent
      When the user settles "env-b:elsewhere"
      Then the node receives no commands
