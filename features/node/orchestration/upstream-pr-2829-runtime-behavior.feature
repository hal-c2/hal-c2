# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   upstream commits 069058c83, 75afe6831, c38c60fcb, f969b217f,
#     175e2bd57, 70629cddd, 6c39f90e9, a4cd40310, 690c57f62,
#     b64278cca, d3179b607, 01dba73a6, 48b51111f, 77acaf553,
#     c48e8a9ce, 77acaf553, 70629cddd (orchestrator runtime recovery and background work)
#   apps/server/src/orchestration-v2/
#   apps/server-ex/lib/hal_c2/orchestration/
Feature: Runtime state remains honest across provider work
  Foreground turns, background work, delegated children and provider sessions
  have separate lifecycles. The node must preserve those boundaries when work
  stops, resumes or moves between processes.

  @node @backlog @plugin-claude
  Scenario: Stopping a Claude turn ends its background work after settlement
    Given Claude has a foreground turn and a background task in thread "t1"
    When the user stops the foreground turn
    And the foreground run settles
    Then the background task is stopped
    And the thread has no running background item

  @node @backlog
  Scenario: Background shell work stays with the run that started it
    Given thread "t1" has two runs and the first run starts a background shell command
    When the second run starts
    Then the shell command remains attached to the first run
    And its completion cannot finish the second run

  @node @backlog @plugin-grok
  Scenario: A provider-finished foreground run is not held by a monitor
    Given Grok has finished the foreground response of thread "t1"
    And a monitor is still reporting progress
    When the node receives the provider's finished signal
    Then the foreground run is settled
    And the monitor remains separate background work

  @node @backlog @shared
  Scenario: A stopped provider command is shown as interrupted
    Given a provider command is running in thread "t1"
    When the user stops the command
    Then the command item is marked interrupted
    And it is not shown as a successful command

  @node @backlog
  Scenario: A native child thread settles during startup recovery
    Given a native provider child thread was running when the node stopped
    When the node starts
    Then the child thread is settled or interrupted
    And it is not left in a running state

  @node @backlog
  Scenario: A resumed child thread keeps the message that resumed it
    Given a child thread was resumed after a restart
    When the resumed turn is projected
    Then the child thread contains the continuation message
    And the message is not incorrectly placed in the parent thread

  @node @backlog @shared
  Scenario: A subagent approval belongs to the parent run
    Given a delegated child requests approval
    When the user answers the approval
    Then the answer is recorded on the parent run
    And the child receives the result

  @node @backlog @shared
  Scenario: A delegated child reports its own model
    Given a parent delegates work to model "model-b"
    When the child appears in thread lineage
    Then the child reports "model-b"
    And the parent model is not substituted for it

  @node @backlog @shared
  Scenario: A completed child with pending work remains visible as pending
    Given a delegated child has returned a result with background work still running
    When the parent reads its delegation state
    Then the child result is visible
    And the pending background work remains visible

  @node @backlog
  Scenario: A wait timeout does not declare a live child dead
    Given a parent is waiting for a live delegated child
    When the wait for the child times out
    Then the child remains live
    And the parent can receive its later completion

  @node @backlog
  Scenario: A late steering message becomes a follow-up turn
    Given a provider has already completed the turn while a steer is being delivered
    When the node receives the steer
    Then the steer becomes a follow-up turn
    And it is not lost or attached to the completed turn

  @node @backlog @shared
  Scenario: A failed or interrupted turn hands its context to the next run
    Given thread "t1" has a failed turn with usable provider context
    When the user sends a new message
    Then the next run receives the preserved context
    And the failed turn remains visible in the transcript

  @node @backlog
  Scenario: A failed output does not replace valid partial output
    Given a provider emitted partial output before failing
    When the failure is projected
    Then the partial output remains attached to the failed run
    And the run is marked failed

  @node @backlog
  Scenario: A repeated rollback preserves provider history
    Given thread "t1" has been rolled back twice
    When the user starts a new run
    Then the provider receives the history through the selected checkpoint
    And neither rolled-back run is replayed

  @node @backlog
  Scenario: Snoozing prevents old failures from waking a thread
    Given thread "t1" is snoozed
    And an earlier run reports a late failure
    When the failure reaches the node
    Then "t1" remains snoozed
    And no wake turn is created

  @node @backlog
  Scenario: A thread visit does not create an activity loop
    Given a client repeatedly visits thread "t1"
    When the node records the visits
    Then visits do not create new turns
    And the thread's activity settles

  @node @backlog
  Scenario: A thread's activity is ordered by creation time
    Given lineage entries were received out of order
    When the node projects the lineage
    Then entries are ordered by their creation time

  @node @backlog @shared
  Scenario: A worktree fetch failure explains the recovery action
    Given preparing thread "t1" fails while fetching its worktree
    When the run fails
    Then the error explains that worktree preparation failed
    And the error tells the user what can be retried or repaired

  @node @backlog
  Scenario: Handoff rollback is atomic
    Given a provider handoff is moving thread "t1" to another provider
    When the handoff fails while restoring the source worktree
    Then the source provider state remains intact
    And no half-created target handoff is published

  @node @backlog
  Scenario: A thread can choose another available provider instance
    Given the selected provider instance is unavailable
    And another instance of the same provider is ready
    When the user starts a run
    Then the node selects the ready instance
    And records which instance ran the turn

  @node @backlog
  Scenario: A run records that its checkpoint baseline is unavailable
    Given capturing the turn-start baseline fails
    When the user sends a message
    Then the run records that its baseline is unavailable

  @node @backlog
  Scenario: Provider startup preparation failure fails the run cleanly
    Given provider startup preparation fails before a provider turn exists
    When the node starts the run
    Then the run fails with the preparation error
    And the thread is not left working

  @node @backlog
  Scenario: A command receipt cannot be replayed across threads
    Given a command receipt was created for thread "t1"
    When a client replays that receipt for thread "t2"
    Then the command is rejected
    And no state in "t2" changes

  @node @backlog
  Scenario: Only visible history is returned by bounded paging
    Given a thread has hidden and visible historical turns
    When a client requests a bounded page of history
    Then the page contains only visible turns
    And the page ends at the true history boundary

  @node @backlog @shared
  Scenario: A provider retry is visible as a retry
    Given a provider retries a failed request
    When the retry is projected
    Then the work log records a provider retry
    And it does not create a second user turn
