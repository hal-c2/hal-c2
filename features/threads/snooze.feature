# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/thread-sidebar.md (Snoozing, Custom snooze, Limited threads, Wake now)
#   packages/client-runtime/src/state/threadSettled.ts (snooze presets, wake labels, canSnooze, raised hand)
#   apps/web/src/components/CustomSnoozeDialog.tsx
#   apps/web/src/components/threadActionMenu.logic.ts (Snooze submenu, Wake thread)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Snoozed section)
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (Snooze, Wake, Woke pill, wake label)
#   packages/contracts/src/shell.ts (thread.snoozeMenu, thread.unsnooze, thread.wokeDismiss)
#   packages/contracts/src/orchestrationV2.ts (thread.snooze, thread.unsnooze, thread.snoozed, thread.unsnoozed)
#   apps/server-ex/lib/hal_c2/orchestration.ex (snooze, unsnooze)

Feature: Snoozing threads
  Snoozing parks a thread until a chosen time. It comes back on its own, or earlier when
  it needs the user.

  Background:
    Given a connected environment with the idle thread "Refactor cart"
    And the local time is Wednesday 10:00

  @mc
  Scenario: Snoozing a thread until a time
    When a client snoozes "Refactor cart" until Wednesday 15:00
    Then "Refactor cart" is snoozed until Wednesday 15:00
    And every connected client lists it as snoozed

  @mc
  Scenario: Unsnoozing a thread
    Given "Refactor cart" is snoozed until tomorrow
    When a client unsnoozes "Refactor cart"
    Then "Refactor cart" is active again

  @desktop
  Scenario: Snoozed threads are shelved in their own section
    Given "Refactor cart" is snoozed until tomorrow
    When the user looks at the thread list
    Then "Refactor cart" is listed in the snoozed section
    And the row says when it will wake

  @desktop
  Scenario: Waking a snoozed thread from the list
    Given "Refactor cart" is snoozed until tomorrow
    When the user wakes "Refactor cart"
    Then "Refactor cart" returns to the active threads

  @desktop
  Scenario: A snoozable thread offers snoozing from the list
    When the user points at "Refactor cart" in the thread list
    Then the user can snooze it from there

  @desktop @mobile @backlog-mobile
  Scenario Outline: Snoozing with a preset
    When the user snoozes "Refactor cart" <preset>
    Then "Refactor cart" wakes <when>

    Examples:
      | preset       | when               |
      | for 1 hour   | Wednesday at 11:00 |
      | for 3 hours  | Wednesday at 13:00 |
      | this evening | Wednesday at 18:00 |
      | tomorrow     | Thursday at 09:00  |
      | next week    | Monday at 09:00    |

  @desktop @mobile @backlog-mobile
  Scenario: "This evening" is not offered when the evening is less than an hour away
    Given the local time is Wednesday 17:30
    When the user opens the snooze choices
    Then "This evening" is not offered

  @desktop @mobile @backlog-mobile
  Scenario: On Sunday "next week" and "tomorrow" are the same choice
    Given the local time is Sunday 10:00
    When the user opens the snooze choices
    Then only one choice wakes the thread on Monday at 09:00

  @desktop @mobile @backlog-mobile
  Scenario Outline: Snoozing until a custom time
    When the user snoozes "Refactor cart" for a custom <amount>
    Then "Refactor cart" wakes <when>

    Examples:
      | amount               | when                       |
      | 45 minutes           | Wednesday at 10:45         |
      | 2 days               | 48 hours after confirming  |
      | date of Friday 08:30 | Friday at 08:30 local time |

  @desktop @mobile @backlog-mobile
  Scenario Outline: A custom snooze time must be in the future and exist
    When the user tries to snooze "Refactor cart" until <time>
    Then the snooze is refused

    Examples:
      | time                                       |
      | Tuesday 09:00                              |
      | an unreadable date                         |
      | a time skipped by a daylight saving change |

  @desktop @mobile @backlog-mobile
  Scenario Outline: The wake time is described in the user's clock format
    Given the user prefers a <clock> clock
    And "Refactor cart" is snoozed until Wednesday 18:00
    When the user looks at the thread
    Then the wake time reads "<label>"

    Examples:
      | clock   | label   |
      | 24-hour | 18:00   |
      | 12-hour | 6:00 PM |

  @desktop @mobile @backlog-mobile
  Scenario: The time left before waking rounds up and is never zero
    Given "Refactor cart" is snoozed until 20 seconds from now
    When the user looks at the snoozed thread
    Then its wake label reads "1m"

  @desktop @mobile @tui @backlog-mobile
  Scenario Outline: A thread that is waiting on the user cannot be snoozed
    Given "Refactor cart" <state>
    When the user tries to snooze "Refactor cart"
    Then snoozing is unavailable

    Examples:
      | state                                  |
      | is waiting for an approval             |
      | is waiting for an answer to a question |
      | has a turn queued that has not started |

  @desktop @mobile @backlog-mobile
  Scenario: A thread with a running agent can be snoozed
    Given the agent is working in "Refactor cart"
    When the user snoozes "Refactor cart" until tomorrow
    Then "Refactor cart" is snoozed

  @mc @desktop @mobile @backlog
  Scenario: A late failure from an earlier run does not wake a snoozed thread
    Given "Refactor cart" is snoozed until tomorrow
    When a run that started before the snooze reports a failure
    Then "Refactor cart" stays snoozed
    And it is not marked as woke

  @desktop @mobile @backlog-mobile
  Scenario Outline: A snoozed thread wakes early when it needs the user
    Given "Refactor cart" is snoozed until tomorrow
    When <event>
    Then "Refactor cart" returns to the active threads
    And it is marked as woke

    Examples:
      | event                                        |
      | the agent asks for an approval               |
      | the agent asks the user a question           |
      | the agent run fails                          |
      | a run that started after the snooze finishes |

  @desktop
  Scenario: Dismissing the woke marker
    Given "Refactor cart" woke from a snooze
    When the user dismisses its woke marker
    Then "Refactor cart" is no longer marked as woke

  @desktop @mobile @backlog-mobile
  Scenario: Opening a woken thread clears its woke marker
    Given "Refactor cart" woke from a snooze
    When the user opens "Refactor cart"
    Then "Refactor cart" is no longer marked as woke

  @desktop
  Scenario: Snoozing several threads at once
    Given the user has selected three threads
    When the user snoozes the selection until tomorrow
    Then all three threads are snoozed until Thursday at 09:00

  @desktop
  Scenario: Some threads in a bulk snooze fail
    Given the user has selected three threads and one cannot be snoozed
    When the user snoozes the selection until tomorrow
    Then two threads are snoozed
    And the user is told "Failed to snooze 1 thread"

  @desktop @mobile @backlog-mobile
  Scenario: A failed snooze is reported
    Given the environment rejects the snooze
    When the user snoozes "Refactor cart" for 1 hour
    Then "Refactor cart" stays active
    And the user is told "Failed to snooze thread"

  @desktop @mobile @backlog-mobile
  Scenario: Snoozing the open thread moves on to the next thread
    Given the user is viewing "Refactor cart"
    When the user snoozes "Refactor cart" until tomorrow
    Then the next thread in the list opens
    And the user can undo the snooze
