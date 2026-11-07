# Sources:
#   https://github.com/pingdotgg/t3code/pull/17118
#   https://github.com/pingdotgg/t3code/pull/21019
#   https://github.com/pingdotgg/t3code/pull/21026
#   https://github.com/pingdotgg/t3code/pull/14887
#   https://github.com/pingdotgg/t3code/pull/26043
#   https://github.com/pingdotgg/t3code/pull/16517
#   https://github.com/pingdotgg/t3code/pull/19099
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/22202
#   https://github.com/pingdotgg/t3code/pull/26208
#   https://github.com/pingdotgg/t3code/pull/26427
#   docs/user/thread-sidebar.md (Snoozing, Custom snooze, Limited threads, Wake now)
#   packages/client-runtime/src/state/threadSettled.ts (snooze presets, wake labels, canSnooze, raised hand)
#   packages/client-runtime/src/state/threadSnoozed.test.ts (early wake rules, a queued turn start expiring after two minutes)
#   apps/web/src/components/CustomSnoozeDialog.tsx
#   apps/web/src/components/threadActionMenu.logic.ts (Snooze submenu, Wake thread)
#   apps/web/src/components/ChatView.tsx (snoozed and woke notices in the open thread)
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

  # Upstream #21019: the phone's thread list kept a snoozed thread shelved past its wake time
  # until something else changed it.
  @backlog @desktop @mobile
  Scenario: A snoozed thread returns to the active threads at its wake time
    Given "Refactor cart" is snoozed until Wednesday 10:30
    And the user is looking at the thread list
    When it is Wednesday 10:30
    Then "Refactor cart" returns to the active threads
    And it is marked as woke

  @desktop
  Scenario: A snoozable thread offers snoozing from the list
    When the user points at "Refactor cart" in the thread list
    Then the user can snooze it from there

  @desktop @mobile @backlog-mobile @priority-high
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

  @desktop @mobile @backlog-mobile @priority-low
  Scenario: "This evening" is not offered when the evening is less than an hour away
    Given the local time is Wednesday 17:30
    When the user opens the snooze choices
    Then "This evening" is not offered

  # Upstream #26043: on the phone a row's snooze choices kept the times from when the row first
  # showed, so after hours "In 1 hour" offered a time already past.
  @backlog @mobile
  Scenario: Snooze choices follow the clock while the app stays open
    Given the thread list opened on Wednesday at 10:00
    When the user opens the snooze choices of "Refactor cart" at 17:30
    Then "In 1 hour" reads 18:30
    And "This evening" is not offered

  @desktop @mobile @backlog-mobile
  Scenario: On Sunday "next week" and "tomorrow" are the same choice
    Given the local time is Sunday 10:00
    When the user opens the snooze choices
    Then only one choice wakes the thread on Monday at 09:00

  # Upstream #26208: the snooze choices are the user's own, a setting of up to 8 options shared
  # by every client of the environment; the defaults are the five fixed choices.
  @backlog @mc @shared
  Scenario: The user chooses their own snooze options
    When the user sets the snooze options to "In 2 hours", "Tomorrow at 21:00" and "Monday at 18:00"
    And the user opens the snooze choices for "Refactor cart" on any device
    Then the choices offered are exactly those three, soonest first
    When the user resets the snooze options
    Then the five default choices are offered again

  # Upstream #26208
  @backlog @shared @priority-low
  Scenario: No more than eight snooze options can be added
    Given the user has 8 snooze options
    When the user tries to add another snooze option
    Then the option is not added

  # Upstream #26208: labels follow the real day gap; a choice for later today is hidden once its time
  # has passed, and choices that wake at the same minute are offered once.
  @backlog @shared
  Scenario Outline: Snooze options are named for when they wake
    Given the local time is <now>
    And the snooze options include "<option>"
    When the user opens the snooze choices
    Then <offered>

    Examples:
      | now              | option             | offered                                        |
      | Sunday 10:00     | Monday at 18:00    | the choice reads "Tomorrow"                    |
      | Wednesday 19:00  | Today at 18:00     | the choice is not offered                      |
      | Wednesday 10:00  | In 8 hours         | only one choice wakes the thread at 18:00      |

  # Upstream #26208: a duration counts from the moment it is chosen, so a menu left open does
  # not shorten it; a set time wakes when the menu said.
  @backlog @shared @priority-low
  Scenario: A snooze choice left open counts from when it is chosen
    Given the user opened the snooze choices at 10:00
    When the user chooses "In 3 hours" at 10:20
    Then "Refactor cart" wakes at 13:20

  # Upstream #26427: the options in settings are listed soonest first, like the menu, and re-sort
  # only once the user leaves the list, so a row never moves while it is edited.
  @backlog @shared @priority-low
  Scenario: Snooze options are kept soonest first without moving while edited
    Given the snooze options are "In 1 hour" and "Tomorrow at 09:00"
    When the user changes "In 1 hour" to "In 20 hours"
    Then the option still reads "In 20 hours" in the same place while the user edits
    When the user leaves the list
    Then "Tomorrow at 09:00" is listed above "In 20 hours"

  # Upstream #26427: the custom snooze choice links to the snooze options.
  @backlog @desktop @tui @priority-low
  Scenario: The custom snooze choice leads to the snooze options
    When the user opens the custom snooze choice for "Refactor cart"
    And the user asks to edit the snooze options
    Then the snooze options in settings are shown

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

  @desktop @mobile @backlog-mobile @priority-low
  Scenario Outline: The wake time is described in the user's clock format
    Given the user prefers a <clock> clock
    And "Refactor cart" is snoozed until Wednesday 18:00
    When the user looks at the thread
    Then the wake time reads "<label>"

    Examples:
      | clock   | label   |
      | 24-hour | 18:00   |
      | 12-hour | 6:00 PM |

  @desktop @mobile @backlog-mobile @priority-low
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

  # A queued message the user wrote still blocks the snooze (above); automatic wakes do not.
  # Upstream #19099: snoozed threads allow queued automatic wakes
  @mc @backlog
  Scenario Outline: A thread with an automatic wake queued can be snoozed
    Given "Refactor cart" has <wake> queued
    When the user snoozes "Refactor cart" until tomorrow
    Then "Refactor cart" is snoozed
    And the wake stays queued

    Examples:
      | wake                                     |
      | a notification wake                      |
      | the completion of a task it delegated    |

  # Upstream #19099: snoozed threads allow queued automatic wakes
  @mc @backlog @priority-low
  Scenario Outline: Wakes held for output that was thrown away are cancelled
    Given "Refactor cart" has a wake queued for a provider notification
    When <discard>
    Then that wake is cancelled
    And a queued message the user wrote stays queued

    Examples:
      | discard                                    |
      | the user stops "Refactor cart"             |
      | the MC recovers "Refactor cart" at startup |
      | the MC shuts down                          |

  # Upstream #2829: the new orchestrator
  @mc @desktop @mobile @backlog @priority-high
  Scenario: A late failure from an earlier run does not wake a snoozed thread
    Given "Refactor cart" is snoozed until tomorrow
    When a run that started before the snooze reports a failure
    Then "Refactor cart" stays snoozed
    And it is not marked as woke

  # Upstream #16517: pull request sync, links, renames and reordering woke snoozed threads; only
  # new activity does now.
  @mc @desktop @mobile @backlog @priority-high
  Scenario Outline: A background update does not wake a snoozed thread
    Given "Refactor cart" is snoozed until tomorrow
    When <update>
    Then "Refactor cart" stays snoozed

    Examples:
      | update                                     |
      | the MC syncs the state of its pull request |
      | a pull request is linked to it             |
      | the user renames it                        |
      | the user reorders the threads              |

  # Upstream #17118: a run requested before the snooze no longer ends it when it completes.
  @desktop @mobile @backlog-mobile @priority-high
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

  # Upstream #22202: a completed run no longer ends a snooze, so a thread that wakes itself
  # for background work stays shelved until its wake time.
  # Replaces the scenario above once desktop and mobile carry it.
  @backlog @mc @desktop @mobile @priority-high
  Scenario Outline: A snoozed thread wakes early only when it needs the user
    Given "Refactor cart" is snoozed until tomorrow
    When <event>
    Then "Refactor cart" returns to the active threads
    And it is marked as woke

    Examples:
      | event                                        |
      | the agent asks for an approval               |
      | the agent asks the user a question           |
      | a run that started after the snooze fails    |

  # Upstream #22202
  @backlog @mc @desktop @mobile @priority-high
  Scenario: A run that finishes does not wake a snoozed thread
    Given "Refactor cart" is snoozed until tomorrow
    When a run that started after the snooze finishes
    Then "Refactor cart" stays snoozed
    And it is not marked as woke

  # Upstream #22202: every automatic message cleared the snooze, so a self-waking thread came
  # back within minutes. A message the user sends still wakes it.
  @backlog @mc @priority-high
  Scenario Outline: An automatic wake keeps a thread snoozed
    Given "Refactor cart" is snoozed until tomorrow
    When <wake> sends "Refactor cart" a message and its run finishes
    Then "Refactor cart" stays snoozed until tomorrow

    Examples:
      | wake                                    |
      | a background task finishing             |
      | a monitor the agent set                 |
      | a pull request watch                    |
      | the completion of a task it delegated   |

  # Upstream #14887: every snooze is stamped afresh, so snoozing a woken thread again until
  # the same time shelves it again; a retried command is still applied once.
  @backlog @mc
  Scenario: A woken thread snoozed again until the same time is shelved again
    Given "Refactor cart" was snoozed until tomorrow 09:00 and woke early because its run failed
    When a client snoozes "Refactor cart" until tomorrow 09:00 again
    Then "Refactor cart" is snoozed until tomorrow 09:00
    And it is no longer among the active threads

  @desktop
  Scenario: Dismissing the woke marker
    Given "Refactor cart" woke from a snooze
    When the user dismisses its woke marker
    Then "Refactor cart" is no longer marked as woke

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: Opening a woken thread clears its woke marker
    Given "Refactor cart" woke from a snooze
    When the user opens "Refactor cart"
    Then "Refactor cart" is no longer marked as woke

  @backlog @desktop @priority-high
  Scenario: An open snoozed thread says so and can be woken there
    Given "Refactor cart" is snoozed until tomorrow
    When the user opens "Refactor cart"
    Then the thread says "This thread is snoozed" and that sending a message wakes it
    When the user chooses "Wake now"
    Then "Refactor cart" is active again

  # Upstream #21019: the open thread's snoozed notice turns into the woke notice at the wake
  # time, without anything else in the thread changing.
  @backlog @desktop
  Scenario: An open snoozed thread says it woke when its wake time comes
    Given the user has opened "Refactor cart", which is snoozed until Wednesday 10:30
    When it is Wednesday 10:30
    Then the thread says "Thread woke from snooze" instead of "This thread is snoozed"

  @backlog @desktop
  Scenario: A wake that fails is reported
    Given the user has opened "Refactor cart", which is snoozed until tomorrow
    And the environment rejects the wake
    When the user chooses "Wake now"
    Then the user is told "Failed to wake thread" with the reason
    And "Refactor cart" stays snoozed

  @backlog @desktop
  Scenario: A thread that woke says so in the conversation until dismissed
    Given "Refactor cart" woke from a snooze and the user has not seen it since
    When the user is shown "Refactor cart"
    Then the thread says "Thread woke from snooze" and to send a message to continue
    When the user dismisses that notice
    Then "Refactor cart" is no longer marked as woke in the thread list either

  @backlog @desktop @priority-low
  Scenario: Sending a message clears the woke notice
    Given "Refactor cart" says it woke from a snooze
    When the user sends a message in "Refactor cart"
    Then the woke notice is gone

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

  @desktop @mobile @backlog-mobile @priority-high
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

  @backlog @desktop @mobile @priority-high
  Scenario: A run that finished before the snooze does not wake the thread
    Given a run in "Refactor cart" finished a minute ago
    And the user snoozes "Refactor cart" until tomorrow
    When the user looks at the thread list
    Then "Refactor cart" is still snoozed
    And it is not marked as woke

  # Upstream #21026: the sidebar row offered snoozing again only once the thread changed, not when the two minutes passed.
  @backlog @desktop @mobile
  Scenario: A turn that never began stops blocking the snooze after two minutes
    Given a message to "Refactor cart" is waiting for its turn to start
    And snoozing is unavailable
    When two minutes pass without the turn starting
    Then the user can snooze "Refactor cart"

  @backlog @desktop @mobile
  Scenario Outline: A waiting turn stops blocking the snooze when it is taken up or fails
    Given a message to "Refactor cart" is waiting for its turn to start
    When <event>
    Then the user can snooze "Refactor cart"

    Examples:
      | event                                    |
      | the agent starts a turn with the message |
      | the agent session fails                  |
