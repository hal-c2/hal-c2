# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (status words, recede, relative age)
#   apps/desktop-qt/tests/tst_SidebarThreadRow.qml
#   apps/desktop-qt/tests/tst_SidebarThreadRowHover.qml
#   apps/tui/src/theme.ts (resolveThreadStatus)
#   apps/tui/src/components/Sidebar.tsx
#   apps/web/src/components/Sidebar.logic.ts (thread status priority, project status)
#   apps/web/src/components/ThreadHoverCard.tsx
#   apps/web/src/components/Sidebar.tsx (the hover preview: branch warning, handoff, last error)
#   apps/web/src/hooks/useThreadVisitedMigration.ts
#   packages/contracts/src/shell.ts (thread.markUnread)
#   packages/contracts/src/orchestrationV2.ts (thread.visit, thread.mark-unread, thread.visited, thread.marked-unread)
#   apps/server-ex/lib/hal_c2/orchestration.ex (visit, mark-unread)
#   apps/web/src/components/ChatView.tsx (a visit for the open thread, once per change)
#   apps/desktop-qt/src/native/SidebarController.cpp (visitOpenThread)

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

  @desktop @mobile @backlog-mobile
  Scenario: The most urgent state wins
    Given "Build search" has an agent working and is waiting for an approval
    When the user looks at the thread list
    Then the row for "Build search" reads "Approval"

  @desktop @mobile @backlog-mobile
  Scenario: A project shows the most urgent state of its threads
    Given one thread in "shop" is working and another is waiting for an approval
    When the user looks at the project "shop"
    Then the project shows that a thread needs an approval

  @desktop @mobile @backlog-mobile
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

  @mc
  Scenario: Opening a thread marks it read on every device
    Given "Build search" finished work the user has not seen
    When the user opens "Build search" on the desktop
    Then "Build search" is read on the phone too

  @desktop
  Scenario: Reading a thread tells the environment it was seen
    Given "Build search" finished work the user has not seen
    When the user opens "Build search"
    Then the environment is told "Build search" was seen up to its latest work

  @mc
  Scenario: A late visit from another device does not make a thread unread again
    Given "Build search" was visited at 10:05 on the desktop
    When the phone reports a visit at 10:01
    Then "Build search" stays read as of 10:05

  @mc
  Scenario: Marking a thread unread
    Given "Build search" is read
    When a client marks "Build search" unread
    Then "Build search" is unread on every device

  @desktop @mobile @backlog-mobile
  Scenario: Marking a thread unread from its menu
    Given "Build search" is read
    When the user marks "Build search" unread
    Then the row for "Build search" reads "Done"

  @backlog @desktop
  Scenario: Marking the open thread unread is not undone by still looking at it
    Given the user has "Build search" open and it is read
    When the user marks "Build search" unread
    Then "Build search" stays unread while it remains open
    When the agent adds to "Build search" or the user leaves and opens it again
    Then "Build search" is read

  @desktop
  Scenario: Marking several threads unread
    Given the user has selected three read threads
    When the user marks the selection unread
    Then all three threads are unread

  @backlog @desktop @mobile
  Scenario: Read state saved by an older client is carried over
    Given this browser remembered which threads the user had seen
    When the user connects to an environment that tracks reads itself
    Then the remembered reads are sent to the environment once

  @desktop
  Scenario: Pointing at a thread previews it
    When the user rests the pointer on "Build search"
    Then a preview shows the thread's project, branch and latest activity

  @backlog @desktop
  Scenario: The preview warns when the checkout is on another branch
    Given "Build search" works on the branch "feature/search"
    And the checkout is on the branch "main"
    When the user rests the pointer on "Build search"
    Then the preview says "You're currently checked out on another branch."

  @backlog @desktop
  Scenario: The preview names the model and the provider instance
    Given the user has two instances of the same provider
    When the user rests the pointer on "Build search"
    Then the preview shows the thread's model and the name of its provider instance

  @backlog @desktop
  Scenario: The preview says which providers a thread was handed off from
    Given "Build search" was handed off from Codex to Claude
    When the user rests the pointer on "Build search"
    Then the preview says "Handed off from Codex"

  @backlog @desktop
  Scenario Outline: The preview says why the thread stopped
    Given the last run of "Build search" ended with <failure>
    When the user rests the pointer on "Build search"
    Then the preview says "<told>"

    Examples:
      | failure                    | told                |
      | the provider's usage limit | Usage limit reached |
      | any other error            | Error occurred      |

  @backlog @desktop
  Scenario: The preview says which machine and terminal processes a thread has
    Given "Build search" is on the environment "work" and has two terminal processes running
    When the user rests the pointer on "Build search"
    Then the preview names the machine "work"
    And the preview says "2 terminal processes running"

  @backlog @desktop
  Scenario: The preview lists the thread's pull requests
    Given "Build search" is linked to pull requests 12 and 14
    When the user rests the pointer on "Build search"
    Then the preview lists both pull requests with their state
