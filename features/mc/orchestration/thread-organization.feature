# Sources:
#   packages/contracts/src/orchestrationV2.ts (thread.settle, thread.settled, thread.unsettle,
#     thread.unsettled, thread.snooze, thread.snoozed, thread.unsnooze, thread.unsnoozed,
#     thread.pin, thread.pinned, thread.unpin, thread.unpinned, thread.pin.reorder,
#     thread.pin-reordered, thread.active.reorder, thread.active-reordered)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread field updates)
#   apps/server/src/orchestration-v2/ (projector for organization fields)
#   apps/server/src/orchestration-v2/Orchestrator.ts (thread mutation guards and field updates,
#     message.dispatch unsettling and unsnoozing its thread, settle stopping the provider session)
#   apps/server/src/orchestration/decider.ts (thread.settle also unpins and unsnoozes)
#   apps/server/src/orchestration/ThreadSettlementPolicy.ts (queued turn start window, both directions)
#   apps/desktop-qt/src/native/SidebarController.cpp (undoing a settle snoozes again)
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

  # The Node server records thread.settled then thread.unsnoozed; the MC records both in
  # the one change it makes to the thread.
  @mc
  Scenario: Settling a snoozed thread ends its snooze
    Given thread "t1" is snoozed until tomorrow 09:00
    When a client settles "t1"
    Then thread "t1" is settled by override
    And thread "t1" has no snooze time and no snoozed-at time
    And a thread-settled event is recorded
    And a thread-unsnoozed event is recorded

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

  # A message from a client whose clock is off still counts as waiting for its turn,
  # but only within two minutes either way; older or further ahead is stale data.
  @backlog @mc
  Scenario Outline: A message no turn has picked up holds the thread only within two minutes of now
    Given the user's newest message on "t1" is stamped <stamped> and no turn has picked it up
    When a client settles "t1"
    Then <result>

    Examples:
      | stamped             | result                                                                    |
      | 30 seconds ago      | the command fails with "Thread t1 has active or blocked work and cannot be settled." |
      | 30 seconds from now | the command fails with "Thread t1 has active or blocked work and cannot be settled." |
      | 5 minutes ago       | thread "t1" is settled by override                                        |
      | 5 minutes from now  | thread "t1" is settled by override                                        |

  @backlog @mc
  Scenario Outline: A message a turn has picked up, or whose session failed, no longer holds the thread
    Given the user's newest message on "t1" arrived 30 seconds ago
    And <condition>
    When a client settles "t1"
    Then thread "t1" is settled by override

    Examples:
      | condition                                                   |
      | a turn requested after that message has ended               |
      | the provider session of "t1" is in an error state           |

  @backlog @mc
  Scenario: A message imported from an agent's history never holds a thread
    Given the newest message on "t1" was imported from an agent session a minute ago
    When a client settles "t1"
    Then thread "t1" is settled by override

  @backlog @mc
  Scenario: Settling a settled thread again changes nothing
    Given thread "t1" is settled
    When a client settles "t1" again
    Then no error is reported
    And thread "t1" keeps its original settled time

  # Settled means done with the thread, so nothing it left running (a monitor, a dev
  # server, subagents) carries on behind it. Archiving does the same (threads.feature).
  @backlog @mc
  Scenario Outline: Settling a thread stops its agent's live session
    Given thread "t1" is idle with a live provider session that left work running in the background
    When <who> settles "t1"
    Then the provider session of "t1" is stopped with the reason "Thread settled."
    And the background work ends with it

    Examples:
      | who                      |
      | a client                 |
      | the MC, automatically    |

  @backlog @mc
  Scenario: Snoozing to the wake time a thread already has changes nothing
    Given thread "t1" is snoozed until tomorrow 09:00
    When a client snoozes "t1" until tomorrow 09:00 again
    Then thread "t1" keeps its original snoozed-at time

  @backlog @mc
  Scenario: Manual settling dismisses a question the provider is not waiting on
    Given thread "t1" waits only for an answer to a question the provider does not block on
    When a client settles "t1"
    Then thread "t1" is settled by override
    And the question is dismissed

  @backlog @mc
  Scenario: Automatic settling never dismisses a pending question
    Given thread "t1" waits only for an answer to a question the provider does not block on
    When the MC settles "t1" automatically
    Then the command fails with "Thread t1 has active or blocked work and cannot be settled."

  @backlog @mc
  Scenario Outline: A settled thread is brought back when the agent needs the user
    Given thread "t1" is settled
    When the provider raises <need> on "t1"
    Then thread "t1" is active by override
    And the request is pending on "t1"

    Examples:
      | need                           |
      | an approval request            |
      | a question for the user        |

  @backlog @mc
  Scenario Outline: A settled thread is brought back when its agent session comes alive
    Given thread "t1" is settled
    When the provider session of "t1" becomes <status>
    Then thread "t1" is active by override

    Examples:
      | status   |
      | starting |
      | running  |

  @backlog @mc
  Scenario Outline: A settled thread stays settled when its agent session only reports an outcome
    Given thread "t1" is settled
    When the provider session of "t1" becomes <status>
    Then thread "t1" is still settled

    Examples:
      | status  |
      | ready   |
      | stopped |
      | error   |

  @backlog @mc
  Scenario: A snoozed thread stays snoozed while its agent session starts
    Given thread "t1" is snoozed until tomorrow 09:00
    When the provider session of "t1" becomes running
    Then thread "t1" is still snoozed until tomorrow 09:00

  @backlog @mc
  Scenario: Automatic settling is refused when the user settled or unsettled the thread first
    Given the MC decided to settle "t1" automatically
    And a client unsettles "t1" before the MC's settle is applied
    When the MC's automatic settle is applied
    Then the command fails with "thread t1 changed before automatic settlement"

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
    # The MC names the thread by its title, which here is "t1"; the Node server by its id.
    Then the command fails with "t1 is already archived."

  @mc
  Scenario: Unarchiving a thread that is not archived is refused
    When a client unarchives "t1"
    Then the command fails with "t1 is not archived."

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

  # Settling clears a pin and a snooze, and pinning clears a settle, so no one thread
  # holds all three.
  @mc
  Scenario: Organization state is per thread and survives an MC restart
    Given thread "t1" is pinned and snoozed
    And thread "t2" exists in "demo"
    And thread "t2" is unsettled and snoozed
    When the MC restarts
    Then thread "t1" is still pinned and snoozed
    And thread "t2" is still unsettled and snoozed
