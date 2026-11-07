# Sources:
#   https://github.com/pingdotgg/t3code/pull/24610
#   https://github.com/pingdotgg/t3code/pull/21500
#   https://github.com/pingdotgg/t3code/pull/20996
#   https://github.com/pingdotgg/t3code/pull/15607
#   https://github.com/pingdotgg/t3code/pull/15430
#   https://github.com/pingdotgg/t3code/pull/19630
#   https://github.com/pingdotgg/t3code/pull/19617
#   https://github.com/pingdotgg/t3code/pull/19355
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
#   https://github.com/pingdotgg/t3code/pull/13673 (idle shells are not busy)
#   apps/server-ex/lib/hal_c2/orchestration.ex (visit, mark-unread)
#   apps/web/src/components/ChatView.tsx (a visit for the open thread, once per change)
#   apps/desktop-qt/src/native/SidebarController.cpp (visitOpenThread)
#   https://github.com/pingdotgg/t3code/pull/14910
#   https://github.com/pingdotgg/t3code/pull/15114
#   https://github.com/pingdotgg/t3code/pull/15029
#   https://github.com/pingdotgg/t3code/pull/15034
#   https://github.com/pingdotgg/t3code/pull/25368
#   https://github.com/pingdotgg/t3code/pull/21394

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

  # Upstream #21394: the phone's rows name the same states as the desktop's.
  @backlog @mobile @priority-high
  Scenario Outline: A phone's thread row names its state
    Given "Build search" <state>
    When the user looks at the thread list on a phone
    Then the row for "Build search" reads "<word>"

    Examples:
      | state                               | word    |
      | has an agent working                | Working |
      | has a queued turn waiting to start  | Waiting |
      | woke early from a snooze            | Woke    |

  # Upstream #21394: Working counts from when the run started, Waiting from when the last
  # one finished, and only the time changes, once a second.
  @backlog @shared
  Scenario: A busy row says how long it has been working
    Given an agent started working in "Build search" 26 seconds ago
    When the user looks at the thread list
    Then the row for "Build search" reads "Working 26s"
    And a second later it reads "Working 27s"

  # Upstream #21394: a wake that passes while the thread is open is seen, so the row does not
  # say Woke when the user goes back.
  @backlog @desktop @mobile
  Scenario: A thread open when its snooze ends does not say Woke afterwards
    Given the user has opened "Build search", which is snoozed until 10:30
    When it is 10:30 and the user goes back to the thread list
    Then the row for "Build search" does not read "Woke"

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

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: The most urgent state wins
    Given "Build search" has an agent working and is waiting for an approval
    When the user looks at the thread list
    Then the row for "Build search" reads "Approval"

  # Upstream #21500: a turn blocked only on another thread showed Working.
  @backlog @shared @mobile @mc
  Scenario: A turn waiting only on another thread reads Waiting
    Given the agent of "Build search" is waiting on a task it delegated and doing nothing else
    When the user looks at the thread list
    Then the row for "Build search" reads "Waiting"
    And it reads "Working" again once the task ends and the turn carries on
    And an approval or a question still wins over Waiting

  # Upstream #15430: a question the agent asked without waiting for the answer showed Input while
  # it kept working; it shows Input once the run ends, and a secret request still shows Input at once.
  @backlog @mc @desktop @mobile @tui
  Scenario: A question the agent does not wait on leaves the thread working
    Given "Build search" has an agent working that asked a question it does not wait on
    When the user looks at the thread list
    Then "Build search" is shown as working
    When the run ends with the question unanswered
    Then "Build search" is shown as waiting for an answer

  @desktop @mobile @backlog-mobile
  Scenario: A project shows the most urgent state of its threads
    Given one thread in "shop" is working and another is waiting for an approval
    When the user looks at the project "shop"
    Then the project shows that a thread needs an approval

  # Upstream #20996: an unseen failed run reads Failed, not Completed
  @backlog @desktop @mobile
  Scenario: A failed run the user has not seen reads Failed
    Given the last run of "Build search" failed and the user has not seen it
    When the user looks at the thread list
    Then the row for "Build search" reads "Failed", not "Done"

  # Upstream #20996: Failed outranks Working when states are rolled up
  @backlog @desktop @mobile
  Scenario: A failed thread outranks a working one in its project
    Given one thread in "shop" is working and another had its last run fail
    When the user looks at the project "shop"
    Then the project shows that a thread failed

  # A delegated subagent's thread has no row of its own, so what it waits on
  # shows on the nearest thread that does. Provider-native subagents already
  # ask on their parent.
  @backlog @shared
  Scenario Outline: A thread whose delegated subagent waits on the user says so
    Given "Build search" delegated a task whose subagent, or its own subagent, <waits>
    When the user looks at the thread list
    Then the row for "Build search" reads "<word>" instead of "Working"
    And the user is alerted "<title>" for "Build search"
    And the composer of "Build search" offers to open the subagent's request
    And "Build search" cannot be snoozed, and wakes if it was snoozed

    Examples:
      | waits                                  | word     | title           |
      | is waiting for an approval             | Approval | Approval needed |
      | is waiting for an answer to a question | Input    | Input needed    |

  @desktop @mobile @backlog-mobile
  Scenario: A working thread shows how long it has been working
    Given the agent has been working in "Build search" for 3 minutes
    When the user looks at the thread
    Then the thread shows it has been working for 3 minutes

  @backlog @desktop
  Scenario: A waiting thread shows how long since its turn ended
    Given the agent in "Build search" ended its turn 3 minutes ago and a background monitor will wake it
    When the user looks at the thread list
    Then the row for "Build search" reads "Waiting" and shows 3 minutes

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

  # Pinning, snoozing, waking and renaming also move the thread's update time; the age
  # does not follow it, as on the web (latestUserMessageAt ?? updatedAt).
  @desktop @mobile @backlog-mobile @tui @backlog-tui @priority-low
  Scenario: Pinning a thread does not change its age
    Given the last message in "Build search" was 3 hours ago
    When the environment records that "Build search" was pinned just now
    Then the row for "Build search" counts its age from that message

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

  # Upstream #25368: a visit to one thread delayed the next thread's visit by up to ten
  # seconds, and leaving that thread sooner left it unread.
  @backlog @desktop @mobile @priority-high
  Scenario: Switching straight to another thread marks it seen at once
    Given "Build search" and "Fix login" both finished work the user has not seen
    When the user opens "Build search" and then switches to "Fix login" within a second
    And the user leaves "Fix login" straight away
    Then the environment is told both threads were seen up to their latest work

  @mc
  Scenario: A late visit from another device does not make a thread unread again
    Given "Build search" was visited at 10:05 on the desktop
    When the phone reports a visit at 10:01
    Then "Build search" stays read as of 10:05

  # Upstream #15607: a thread never opened finished without showing as unread.
  @backlog @mc @priority-high
  Scenario: A thread the user never opened is unread when it finishes
    Given a thread was started in the background and the user has not opened it
    When its agent finishes
    Then the thread is unread
    And opening it marks it read

  # Upstream #15607: imported history and the MC's own maintenance leave a thread's reads unset.
  @backlog @mc
  Scenario: A thread imported with its finished history is not unread
    Given a thread was imported with its finished history and nobody has opened it
    When a client lists the environment's threads
    Then the thread is not unread

  @mc
  Scenario: Marking a thread unread
    Given "Build search" is read
    When a client marks "Build search" unread
    Then "Build search" is unread on every device

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: Marking a thread unread from its menu
    Given "Build search" is read
    When the user marks "Build search" unread
    Then the row for "Build search" reads "Done"

  @backlog @desktop @priority-high
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

  # Proved by tst_SidebarThreadRowHover.qml (test_previewStaysInTheRowColumn).
  @desktop @backlog-desktop
  Scenario: The preview stays in the thread list
    When the user rests the pointer on "Build search"
    Then the preview shows under the row, as wide as the thread list at most
    And it never covers the thread beside the list
    When the row is the last one above the window's bottom edge
    Then the preview shows over the row instead

  @backlog @desktop @priority-low
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

  @backlog @desktop @priority-low
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

  # Upstream #13673: zsh prompt helpers made idle shells look busy.
  @mc @desktop @tui @backlog-desktop @backlog-tui @priority-high
  Scenario: An idle shell does not make its thread look busy
    Given "Build search" has one terminal waiting at an idle prompt
    Then "Build search" is not shown as busy

  @backlog @desktop @priority-low
  Scenario: The preview lists the thread's pull requests
    Given "Build search" is linked to pull requests 12 and 14
    When the user rests the pointer on "Build search"
    Then the preview lists both pull requests with their state

  @backlog @shared
  Scenario: A thread that left a shell running shows its unseen completion
    Given an agent ended its turn leaving only a background shell running
    When the user is in another thread
    Then its row reads Done and unread, not Waiting

  # Upstream #24610: a monitor waits only when the agent marks it as work it waits on.
  @backlog @shared
  Scenario: A left-over dev server does not read as waiting
    Given an agent ended its turn leaving a dev server running
    Then the status strip reads "Running: <command>" with a still dot
    And only subagents and work the agent waits on read "Waiting on" with a pulse
    And Stop is still offered

  @backlog @mc @priority-high
  Scenario Outline: A thread whose session was released stops reading Waiting
    Given a <provider> thread ended its turn with background work running in its session
    When the thread is <released>
    Then the background work the session took with it is no longer listed
    And the thread does not read Waiting or offer Stop
    But work a replacement session reported in the meantime stays listed

    Examples:
      | provider | released                         |
      | Claude   | settled                          |
      | Claude   | archived                         |
      | Claude   | released after its session idled |
      | Muse     | settled                          |

  # OpenCode's background subagents run on a server its sessions share and can
  # outlive the session, so its list is kept.
  @backlog @mc @priority-low
  Scenario: An OpenCode thread keeps its background work when its session is released
    Given an OpenCode thread ended its turn with a background subagent running
    When the thread is settled
    Then the subagent is still listed

  @backlog @shared @priority-high
  Scenario: Working timers survive background wakes
    Given a thread has been running for 30 minutes
    When a background command finishes and wakes the agent
    Then the Working timer keeps counting from the original start

  @backlog @shared @priority-high
  Scenario: Dismissing Woke clears it on every device
    Given a thread shows Woke
    When the user dismisses it from the pill or the chat banner
    Then it is dismissed on the user's other devices too
