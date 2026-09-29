# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (status words, recede, relative age)
#   apps/desktop-qt/tests/tst_SidebarThreadRow.qml
#   apps/desktop-qt/tests/tst_SidebarThreadRowHover.qml
#   apps/tui/src/theme.ts (resolveThreadStatus)
#   apps/tui/src/components/Sidebar.tsx
#   apps/web/src/components/Sidebar.logic.ts (thread status priority, project status)
#   apps/web/src/components/ThreadHoverCard.tsx
#   apps/web/src/hooks/useThreadVisitedMigration.ts
#   packages/contracts/src/shell.ts (thread.markUnread)
#   packages/contracts/src/orchestrationV2.ts (thread.visit, thread.mark-unread, thread.visited, thread.marked-unread)
#   apps/server-ex/lib/hal_c2/orchestration.ex (visit, mark-unread)

Feature: Unread and status in the thread list
  Each thread says whether it needs the user, is busy, or has finished work the user has
  not seen yet. Rows that need nothing step back.

  Background:
    Given a connected environment with the thread "Build search" in the project "shop"

  @desktop
  Scenario Outline: A thread row names its state
    Given "Build search" <state>
    When the user looks at the thread list
    Then the row for "Build search" reads "<word>"

    Examples:
      | state                                  | word     |
      | has an agent working                   | Working  |
      | has a queued turn waiting to start     | Waiting  |
      | is waiting for an approval             | Approval |
      | is waiting for an answer to a question | Input    |
      | has hit a usage limit                  | Limited  |
      | had its last run fail                  | Failed   |
      | woke early from a snooze               | Woke     |
      | finished work the user has not seen    | Done     |

  @tui
  Scenario Outline: The terminal thread list names the thread's state
    Given "Build search" <state>
    When the user looks at the thread list
    Then the row for "Build search" reads "<label>"

    Examples:
      | state                                  | label            |
      | is waiting for an approval             | Pending approval |
      | is waiting for an answer to a question | Awaiting input   |
      | has a plan ready to review             | Plan ready       |
      | has an agent working                   | Working          |
      | is starting its agent session          | Connecting       |
      | had its last run fail                  | Error            |
      | finished work the user has not seen    | Completed        |

  @backlog @desktop @mobile
  Scenario: The most urgent state wins
    Given "Build search" has an agent working and is waiting for an approval
    When the user looks at the thread list
    Then the row for "Build search" reads "Approval"

  @backlog @desktop @mobile
  Scenario: A project shows the most urgent state of its threads
    Given one thread in "shop" is working and another is waiting for an approval
    When the user looks at the project "shop"
    Then the project shows that a thread needs an approval

  @backlog @desktop @mobile
  Scenario: A working thread shows how long it has been working
    Given the agent has been working in "Build search" for 3 minutes
    When the user looks at the thread
    Then the thread shows it has been working for 3 minutes

  @desktop
  Scenario Outline: An idle thread shows its age
    Given the last activity in "Build search" was <ago>
    When the user looks at the thread list
    Then the row for "Build search" shows "<age>"

    Examples:
      | ago            | age |
      | 20 seconds ago | now |
      | 5 minutes ago  | 5m  |
      | 3 hours ago    | 3h  |
      | 2 days ago     | 2d  |
      | 3 months ago   | 3mo |

  @desktop
  Scenario: The age keeps up while nothing changes
    Given the last activity in "Build search" was 5 minutes ago
    When a minute passes without any update
    Then the row for "Build search" shows "6m"

  @desktop
  Scenario: Threads that need nothing step back
    Given "Build search" is idle and read
    And "Fix cart" finished work the user has not seen
    When the user looks at the thread list
    Then "Fix cart" stands out more than "Build search"

  @desktop
  Scenario: Pointing at a row does not flash it
    Given the user uses a light theme
    When the user moves the pointer onto "Build search"
    Then the row highlights without flashing gray

  @desktop
  Scenario: Moving across a row's actions keeps the row highlighted
    When the user moves the pointer across the actions of "Build search"
    Then the row stays highlighted the whole time

  @node
  Scenario: Opening a thread marks it read on every device
    Given "Build search" finished work the user has not seen
    When the user opens "Build search" on the desktop
    Then "Build search" is read on the phone too

  @node
  Scenario: A late visit from another device does not make a thread unread again
    Given "Build search" was visited at 10:05 on the desktop
    When the phone reports a visit at 10:01
    Then "Build search" stays read as of 10:05

  @node
  Scenario: Marking a thread unread
    Given "Build search" is read
    When a client marks "Build search" unread
    Then "Build search" is unread on every device

  @backlog @desktop @mobile
  Scenario: Marking a thread unread from its menu
    Given "Build search" is read
    When the user marks "Build search" unread
    Then the row for "Build search" reads "Done"

  @backlog @desktop
  Scenario: Marking several threads unread
    Given the user has selected three read threads
    When the user marks the selection unread
    Then all three threads are unread

  @backlog @desktop @mobile
  Scenario: Read state saved by an older client is carried over
    Given this browser remembered which threads the user had seen
    When the user connects to an environment that tracks reads itself
    Then the remembered reads are sent to the environment once

  @backlog @desktop
  Scenario: Pointing at a thread previews it
    When the user rests the pointer on "Build search"
    Then a preview shows the thread's project, branch and latest activity
