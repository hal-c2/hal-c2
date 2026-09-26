# Sources:
#   packages/contracts/src/orchestrationV2.ts (thread.auto-settle, thread.settled)
#   packages/contracts/src/settings.ts (sidebarAutoSettleOnMerge, sidebarAutoSettleAfterDays)
#   apps/server-ex/lib/hal_c2/orchestration/settlement.ex
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.auto-settle)
#   apps/server/src/orchestration-v2/ (auto-settle reactor)
#   docs/user/thread-sidebar.md
Feature: Threads settle on their own
  A thread that is done, because its pull request merged or closed or because
  nobody has touched it for days, settles itself. Anything that shows the thread
  still needs attention keeps it active.

  Background:
    Given a node with a project "demo"
    And auto-settle after 3 days and auto-settle on merge are on

  @node
  Scenario: A quiet thread settles after the configured number of days
    Given thread "t1" finished its last turn 4 days ago
    When the node sweeps for threads to settle
    Then thread "t1" is settled
    And its settled time is its last user activity

  @node
  Scenario: A thread quiet for less than the configured days stays active
    Given thread "t1" finished its last turn 2 days ago
    When the node sweeps for threads to settle
    Then thread "t1" is not settled

  @node
  Scenario: A thread whose pull request merged settles
    Given thread "t1" links a pull request that merged after the user last worked in it
    When the node sweeps for threads to settle
    Then thread "t1" is settled

  @node
  Scenario: A thread whose pull request closed settles
    Given thread "t1" links a pull request that closed after the user last worked in it
    When the node sweeps for threads to settle
    Then thread "t1" is settled

  @node
  Scenario: A merged pull request does not settle the thread when settle-on-merge is off
    Given auto-settle on merge is off
    And thread "t1" links a pull request that merged an hour ago
    When the node sweeps for threads to settle
    Then thread "t1" is not settled

  @node
  Scenario: A pull request that merged before the user's last message does not settle the thread
    Given thread "t1" links a pull request that merged yesterday
    And the user sent a message in "t1" today
    When the node sweeps for threads to settle
    Then thread "t1" is not settled

  @node
  Scenario: An open pull request keeps the thread active
    Given thread "t1" links an open pull request
    And thread "t1" finished its last turn 10 days ago
    When the node sweeps for threads to settle
    Then thread "t1" is not settled

  @node
  Scenario: A linked pull request that has not synced yet keeps the thread active
    Given thread "t1" links a pull request whose state is not known yet
    When the node sweeps for threads to settle
    Then thread "t1" is not settled

  # docs/user/thread-sidebar.md says pinning does not prevent automatic settlement, but
  # both apps/server-ex settlement.ex and apps/server ThreadSettlementService.ts skip
  # pinned threads, as the "is pinned" row below records. hal-c2 keeps the code's
  # behaviour; the docs line is stale. User view: threads/settle.feature.
  @node
  Scenario Outline: A thread that still needs attention never auto-settles
    Given thread "t1" finished its last turn 10 days ago
    And thread "t1" <condition>
    When the node sweeps for threads to settle
    Then thread "t1" is not settled

    Examples:
      | condition                                        |
      | is archived                                      |
      | was settled or unsettled by the user             |
      | is pinned                                        |
      | waits on an approval or a question               |
      | has a running turn                               |
      | has background tasks still running               |
      | received a message less than two minutes ago     |
      | is snoozed and has not woken since               |

  @node
  Scenario: A snoozed thread that woke because a turn completed after the snooze can settle
    Given thread "t1" was snoozed and a turn completed after the snooze
    And its linked pull request merged after that
    When the node sweeps for threads to settle
    Then thread "t1" is settled

  @node
  Scenario: A project override replaces the global auto-settle settings
    Given project "demo" sets auto-settle after 1 day
    And thread "t1" finished its last turn 2 days ago
    When the node sweeps for threads to settle
    Then thread "t1" is settled

  @node
  Scenario: The node re-sweeps when the settings change
    Given thread "t1" finished its last turn 2 days ago
    When the user changes auto-settle to 1 day
    Then thread "t1" is settled without waiting for the next periodic sweep

  @node
  Scenario: The node sweeps periodically
    Given thread "t1" becomes eligible to settle
    When a minute passes
    Then thread "t1" is settled

  @node
  Scenario: Auto-settle is refused when the thread changed after the snapshot it was based on
    Given the node decided to settle "t1" from a snapshot
    And thread "t1" was updated after that snapshot
    When the auto-settle command runs
    Then the command is refused
    And thread "t1" is not settled

  @node
  Scenario: Auto-settle never overrides the user's own settle decision
    Given the user unsettled "t1"
    When an auto-settle command for "t1" runs
    Then the command is refused
    And thread "t1" stays active by override

  @node
  Scenario: Unsettling an auto-settled thread keeps it active on later sweeps
    Given thread "t1" was auto-settled
    When a client unsettles "t1"
    And the node sweeps for threads to settle
    Then thread "t1" is not settled
