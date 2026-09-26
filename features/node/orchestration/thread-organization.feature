# Sources:
#   packages/contracts/src/orchestrationV2.ts (thread.settle, thread.settled, thread.unsettle,
#     thread.unsettled, thread.snooze, thread.snoozed, thread.unsnooze, thread.unsnoozed,
#     thread.pin, thread.pinned, thread.unpin, thread.unpinned, thread.pin.reorder,
#     thread.pin-reordered, thread.active.reorder, thread.active-reordered)
#   apps/server-ex/lib/t3/orchestration.ex (thread field updates)
#   apps/server/src/orchestration-v2/ (projector for organization fields)
#   apps/server/src/orchestration-v2/Orchestrator.ts (thread.snooze and thread.archive guards)
#   apps/web/src/hooks/useThreadActions.ts (ThreadSnoozeBlockedError, ThreadArchiveBlockedError)
#   docs/user/thread-sidebar.md
Feature: Organizing threads in the engine
  Settling, snoozing, pinning and ordering are thread fields the engine owns, so
  every client sees the same organization. Each has a reverse.

  Background:
    Given a node with a project "demo"
    And thread "t1" exists in "demo"

  @node
  Scenario: Settling a thread overrides its computed state
    When a client settles "t1"
    Then thread "t1" is settled by override
    And thread "t1" records when it was settled
    And a thread-settled event is recorded

  @node
  Scenario: Unsettling a thread pins it active and records when
    Given thread "t1" is settled
    When a client unsettles "t1"
    Then thread "t1" is active by override
    And thread "t1" has no settled time
    And thread "t1" records when it was unsettled
    And a thread-unsettled event is recorded

  @node
  Scenario: Snoozing a thread until a time
    When a client snoozes "t1" until tomorrow 09:00
    Then thread "t1" is snoozed until tomorrow 09:00
    And thread "t1" records when it was snoozed
    And a thread-snoozed event is recorded

  @node
  Scenario: Unsnoozing a thread clears both snooze times
    Given thread "t1" is snoozed until tomorrow 09:00
    When a client unsnoozes "t1"
    Then thread "t1" has no snooze time and no snoozed-at time
    And a thread-unsnoozed event is recorded

  @node
  Scenario: Snoozing again replaces the earlier snooze
    Given thread "t1" is snoozed until tomorrow 09:00
    When a client snoozes "t1" until next Monday 09:00
    Then thread "t1" is snoozed until next Monday 09:00

  @node
  Scenario: Pinning a thread places it among the pinned threads
    When a client pins "t1" with order key "a0"
    Then thread "t1" is pinned with order key "a0"
    And a thread-pinned event is recorded

  @node
  Scenario: Unpinning a thread forgets its pinned place
    Given thread "t1" is pinned with order key "a0"
    When a client unpins "t1"
    Then thread "t1" is not pinned and has no pinned order key
    And a thread-unpinned event is recorded

  @node
  Scenario: Reordering pinned threads changes only the order key
    Given thread "t1" is pinned with order key "a0"
    When a client moves pinned thread "t1" to order key "b0"
    Then thread "t1" is pinned with order key "b0"
    And the time it was pinned is unchanged

  @node
  Scenario: Reordering active threads records an active order key
    When a client moves active thread "t1" to order key "c0"
    Then thread "t1" has active order key "c0"
    And a thread-active-reordered event is recorded

  # The web and TUI clients also hide the action.
  @node
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
  @node @backlog
  Scenario: The engine refuses to archive a thread whose agent is running
    Given thread "t1" has a running turn
    When a client archives "t1"
    Then the command fails because the agent is still working
    And thread "t1" is not archived

  @node
  Scenario: Archiving an archived thread is refused
    Given thread "t1" is archived
    When a client archives "t1"
    # Both servers name the thread in the refusal.
    Then the command fails with "Thread t1 is already archived."

  @node
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

  @node
  Scenario: Organization state is per thread and survives a node restart
    Given thread "t1" is pinned, snoozed and settled
    When the node restarts
    Then thread "t1" is still pinned, snoozed and settled
