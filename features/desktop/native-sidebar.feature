# Sources:
#   apps/desktop-qt/src/native/SidebarController.cpp (the row actions it does not send)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   threads/thread-list.feature has what the desktop's sidebar does against its MC; this file
#   keeps what it does not send.

Feature: What the desktop's sidebar does not send to its MC
  The desktop sends row actions to its MC itself. What its MC cannot take, it does not send.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title  | createdAt            | settledOverride | snoozedUntil         |
      | t1 | p1      | First  | 2026-09-23T09:50:00Z |                 |                      |
      | t2 | p1      | Second | 2026-09-23T09:40:00Z |                 |                      |
      | t3 | p2      | Third  | 2026-09-23T09:30:00Z |                 |                      |
      | t4 | p1      | Done   | 2026-09-23T09:20:00Z | settled         |                      |
      | t5 | p2      | Later  | 2026-09-23T09:10:00Z |                 | 2026-09-24T09:00:00Z |
    And the MC has the project "p1" titled "proj-1"
    And the MC has the project "p2" titled "proj-2"
    And the desktop shell is connected to its MC

  Rule: What the MC cannot take is not sent

    @desktop
    Scenario Outline: An environment that does not track visits is sent no unread markers
      Given the MC's environment does not track visits
      And the MC sends its snapshot
      When the user dispatches "<action>" for "env-a:t1"
      Then the MC receives no commands

      Examples:
        | action             |
        | thread.markUnread  |
        | thread.wokeDismiss |

    @desktop
    Scenario: A thread the MC's cluster does not know is not sent
      When the user settles "env-b:elsewhere"
      Then the MC receives no commands
