# Sources:
#   packages/contracts/src/orchestrationV2.ts (thread.settle, thread.settled, thread.unsettle,
#     thread.unsettled, thread.snooze, thread.snoozed, thread.unsnooze, thread.unsnoozed,
#     thread.pin, thread.pinned, thread.unpin, thread.unpinned, thread.pin.reorder,
#     thread.pin-reordered, thread.active.reorder, thread.active-reordered)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread field updates)
#   apps/server/src/orchestration-v2/ (projector for organization fields)
#   apps/server/src/orchestration-v2/Orchestrator.ts (thread mutation guards and field updates,
#     message.dispatch unsettling and unsnoozing its thread)
#   apps/web/src/hooks/useThreadActions.ts (ThreadSnoozeBlockedError, ThreadArchiveBlockedError)
#   docs/user/thread-sidebar.md
Feature: Organizing threads in the engine
  Settling, snoozing, pinning and ordering are thread fields the engine owns, so
  every client sees the same organization. Each has a reverse.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo"

  @mc
  Scenario: Settling a thread overrides its computed state
    When a client settles "t1"
    Then thread "t1" is settled by override
    And thread "t1" records when it was settled
    And a thread-settled event is recorded

  @mc
  Scenario: Unsettling a thread pins it active and records when
    Given thread "t1" is settled
    When a client unsettles "t1"
    Then thread "t1" is active by override
    And thread "t1" has no settled time
    And thread "t1" records when it was unsettled
    And a thread-unsettled event is recorded

  @mc
  Scenario: Snoozing a thread until a time
    When a client snoozes "t1" until tomorrow 09:00
    Then thread "t1" is snoozed until tomorrow 09:00
    And thread "t1" records when it was snoozed
    And a thread-snoozed event is recorded

  @mc
  Scenario: Unsnoozing a thread clears both snooze times
    Given thread "t1" is snoozed until tomorrow 09:00
    When a client unsnoozes "t1"
    Then thread "t1" has no snooze time and no snoozed-at time
    And a thread-unsnoozed event is recorded

  @mc
  Scenario: Snoozing again replaces the earlier snooze
    Given thread "t1" is snoozed until tomorrow 09:00
    When a client snoozes "t1" until next Monday 09:00
    Then thread "t1" is snoozed until next Monday 09:00

  @mc
  Scenario: Pinning a thread places it among the pinned threads
    When a client pins "t1" with order key "a0"
    Then thread "t1" is pinned with order key "a0"
    And a thread-pinned event is recorded

  @mc
  Scenario: Unpinning a thread forgets its pinned place
    Given thread "t1" is pinned with order key "a0"
    When a client unpins "t1"
    Then thread "t1" is not pinned and has no pinned order key
    And a thread-unpinned event is recorded

  @mc
  Scenario: Reordering pinned threads changes only the order key
    Given thread "t1" is pinned with order key "a0"
    When a client moves pinned thread "t1" to order key "b0"
    Then thread "t1" is pinned with order key "b0"
    And the time it was pinned is unchanged

  @mc
  Scenario: Reordering active threads records an active order key
    When a client moves active thread "t1" to order key "c0"
    Then thread "t1" has active order key "c0"
    And a thread-active-reordered event is recorded

  @mc
  Scenario: Only a pinned thread can be reordered among the pinned
    When a client moves pinned thread "t1" to order key "b0"
    Then the command fails with "Thread t1 is not pinned and cannot be reordered."

  @mc
  Scenario Outline: Only an active thread can be reordered among the active
    Given thread "t1" <state>
    When a client moves active thread "t1" to order key "c0"
    Then the command fails with "Thread t1 is not active and cannot be reordered."

    Examples:
      | state                         |
      | is pinned with order key "a0" |
      | is settled                    |

  @mc
  Scenario: Settling a pinned thread takes it out of the pinned threads
    Given thread "t1" is pinned with order key "a0"
    When a client settles "t1"
    Then thread "t1" is settled by override
    And thread "t1" is not pinned and has no pinned order key

  @mc
  Scenario Outline: Pinning a settled or snoozed thread brings it back
    Given thread "t1" <parked>
    When a client pins "t1" with order key "a0"
    Then thread "t1" is pinned with order key "a0"
    And thread "t1" is neither settled nor snoozed

    Examples:
      | parked                          |
      | is settled                      |
      | is snoozed until tomorrow 09:00 |

  @mc
  Scenario Outline: A new message brings a settled or snoozed thread back
    Given thread "t1" <parked>
    When the user sends a message to "t1"
    Then thread "t1" is neither settled nor snoozed

    Examples:
      | parked                          |
      | is settled                      |
      | is snoozed until tomorrow 09:00 |

  @mc
  Scenario Outline: The engine refuses to settle a thread that is still working
    Given thread "t1" <state>
    When a client settles "t1"
    Then the command fails with "Thread t1 has active or blocked work and cannot be settled."

    Examples:
      | state                                 |
      | has a running turn                    |
      | waits for an approval                 |
      | waits for an answer to a question     |
      | has a queued run that has not started |

  # A delegated task's result only wakes the agent; it is not the user's work.
  @mc
  Scenario: Settling cancels a delegated task result waiting to wake the agent
    Given thread "t1" has a delegated task result queued
    When a client settles "t1"
    Then thread "t1" is settled by override
    And the queued delegated task result is cancelled

  # The web and TUI clients also hide the action.
  @mc
  Scenario Outline: The engine refuses to snooze a thread that cannot rest
    Given thread "t1" <state>
    When a client snoozes "t1" until <until>
    Then the command fails and "t1" is not snoozed

    Examples:
      | state                                  | until          |
      | waits for an approval                  | tomorrow 09:00 |
      | waits for an answer to a question      | tomorrow 09:00 |
      | has a queued run that has not started  | tomorrow 09:00 |
      | is idle                                | a past time    |

  # Only the web and TUI clients refuse this today; neither server does.
  @mc @backlog
  Scenario: The engine refuses to archive a thread whose agent is running
    Given thread "t1" has a running turn
    When a client archives "t1"
    Then the command fails because the agent is still working
    And thread "t1" is not archived

  @mc
  Scenario: Archiving an archived thread is refused
    Given thread "t1" is archived
    When a client archives "t1"
    # Both servers name the thread in the refusal.
    Then the command fails with "Thread t1 is already archived."

  @mc
  Scenario: Unarchiving a thread that is not archived is refused
    When a client unarchives "t1"
    Then the command fails with "Thread t1 is not archived."

  @mc
  Scenario Outline: An archived thread is not organized until it is unarchived
    Given thread "t1" is archived
    When a client sends "<command>" for thread "t1"
    Then the command fails with "Thread t1 is archived."

    Examples:
      | command               |
      | thread.settle         |
      | thread.unsettle       |
      | thread.snooze         |
      | thread.unsnooze       |
      | thread.pin            |
      | thread.unpin          |
      | thread.pin.reorder    |
      | thread.active.reorder |

  @mc
  Scenario Outline: Organization commands on an unknown thread are refused
    When a client sends "<command>" for thread "missing"
    Then the command fails with "unknown thread missing"

    Examples:
      | command               |
      | thread.settle         |
      | thread.unsettle       |
      | thread.snooze         |
      | thread.unsnooze       |
      | thread.pin            |
      | thread.unpin          |
      | thread.pin.reorder    |
      | thread.active.reorder |

  # Settling clears a pin and pinning clears a settle, so no one thread holds all three.
  @mc
  Scenario: Organization state is per thread and survives an MC restart
    Given thread "t1" is pinned and snoozed
    And thread "t2" exists in "demo"
    And thread "t2" is snoozed and settled
    When the MC restarts
    Then thread "t1" is still pinned and snoozed
    And thread "t2" is still snoozed and settled
