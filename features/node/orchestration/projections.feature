# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.updated, thread.removed, project.updated,
#     project.removed, shell and thread projection schemas)
#   packages/contracts/src/rpc.ts (orchestration.getThreadProjection, orchestration.subscribeShell,
#     orchestration.subscribeThread, orchestration.subscribeArchivedShell,
#     orchestration.getArchivedShellSnapshot)
#   apps/server-ex/lib/hal_c2/projection/shell.ex, thread_error.ex, background_work.ex, timeline.ex
#   apps/server-ex/lib/hal_c2/orchestration.ex (getArchivedShellSnapshot)
#   apps/server/src/orchestration-v2/ (projector, shell and thread projections)
Feature: What the engine projects for clients
  Clients render projections, not raw entities. A thread's shell row summarizes
  it for lists without message bodies; its timeline decides which items show.

  Background:
    Given a node with a project "demo"
    And thread "t1" exists in "demo"

  @node
  Scenario Outline: The shell row status follows the latest run
    Given the latest run of "t1" is <status>
    Then the shell row of "t1" has status "<status>"

    Examples:
      | status      |
      | queued      |
      | running     |
      | waiting     |
      | completed   |
      | failed      |
      | interrupted |
      | cancelled   |
      | rolled_back |

  @node
  Scenario: A thread with no runs is idle
    Then the shell row of "t1" has status "idle"

  @node
  Scenario: The active run is the latest one preparing, starting or running
    Given run 2 of "t1" is running
    Then the shell row names run 2 as the active run and its activity status is running

  @node
  Scenario: A waiting run is activity but not an interruptible active run
    Given run 2 of "t1" is waiting
    Then the shell row has no active run
    And its activity status is waiting

  @node
  Scenario: A pending request shows on the shell row
    Given the provider asked for approval of a command in "t1"
    Then the shell row of "t1" shows the pending request's id, kind and time

  @node
  Scenario: Shell rows never carry message bodies
    Given "t1" has a long conversation
    Then the shell row of "t1" has no latest visible message text
    And it records when the latest user message was sent

  @node
  Scenario: A thread with an active proposed plan is marked actionable
    Given "t1" has an active proposed plan
    Then the shell row of "t1" has an actionable proposed plan
    And the mark clears when the plan is completed

  @node
  Scenario: Background work that outlives a turn is listed
    Given the latest run of "t1" completed while a background command kept running
    Then the shell row of "t1" lists that background task

  @node
  Scenario: No background work is listed while a foreground run is active
    Given run 2 of "t1" is running and a background command from run 1 is still active
    Then the shell row of "t1" lists no background tasks

  @node @backlog
  Scenario: Background work stays with the run that started it
    Given run 1 of "t1" started a background shell command
    When run 2 of "t1" starts
    Then the command stays attached to run 1
    And its completion cannot finish run 2

  @node
  Scenario: A rolled-back latest run abandons its background work
    Given the latest run of "t1" was rolled back while a background command ran
    Then the shell row of "t1" lists no background tasks

  @node
  Scenario: The thread error comes from the failed root turn of the latest run
    Given the latest run of "t1" failed with a usage limit error that resets at 15:00
    Then the shell row of "t1" shows that error, its class and the reset time

  @node
  Scenario: A different provider session error supersedes the classification
    Given the latest run of "t1" failed and the provider session reports a different error
    # A distinct session error carries no class; both servers drop the turn's classification.
    Then the shell row of "t1" shows the session's error without the turn's classification

  @node
  Scenario: An error from an earlier run is not shown after a later run succeeds
    Given run 1 of "t1" failed and run 2 completed
    Then the shell row of "t1" shows no error

  @node
  Scenario: Provider history lists the instances that owned the root conversation
    Given "t1" ran on "codex" and then "claudeAgent", and delegated a task to "opencode"
    Then the provider history of "t1" is "codex", "claudeAgent"

  @node
  Scenario: A fork counts its source's history among its visible items
    Given "f1" is a fork of "t1" after 10 items and has 3 items of its own
    Then the shell row of "f1" counts 3 own items and more than 10 visible items

  @node
  Scenario Outline: The timeline hides items that no longer belong to the conversation
    Given "t1" has <items>
    When a client reads the timeline of "t1"
    Then those items are not shown

    Examples:
      | items                                                      |
      | items of a rolled-back run                                  |
      | a queued message whose run was cancelled                    |
      | an unpaired interrupt result of a superseded attempt        |

  @node
  Scenario: A legacy model selection naming a provider is shown with an instance id
    Given "t1" was stored with a model selection that names provider "codex"
    Then the shell row of "t1" shows instance "codex" and the model

  @node
  Scenario: The archived shell snapshot lists archived threads and their projects
    Given "t1" is archived and "t2" is active and "t3" is archived and deleted
    When a client asks for the archived shell snapshot
    Then it contains "t1" and project "demo"
    And it does not contain "t2" or "t3"

  @node
  Scenario: The shell row's activity time is the time of the thread's latest event
    Given the latest event on "t1" happened at 10:00
    Then the shell row of "t1" was updated at 10:00

  # The node answers this with hal-c2.threadRows; orchestration.getThreadProjection itself
  # is refused below (parity/rpc.feature).
  @node
  Scenario: A client reads a thread's full projection with one request
    Given "t1" has a finished run with a message, an item, a plan, a checkpoint and a pending request
    When a client asks for the projection of "t1"
    Then it receives the thread, its runs, items, messages, plans, checkpoints and requests
    And it receives the sequence the projection is at

  @node @backlog
  Scenario: Subscribing to a thread sends a bounded snapshot and then live events
    Given "t1" has a very long history
    When a client subscribes to "t1"
    Then it receives the newest part of the history with a marker that older history exists
    And it can page older history on request
    And then it receives live events after the snapshot's sequence

  @node @backlog
  Scenario: A bounded page of history holds only visible turns
    Given "t1" has hidden and visible earlier turns
    When a client asks for a bounded page of the history of "t1"
    Then the page holds only visible turns
    And it ends at the true start of the history

  @node
  Scenario: Subscribing after a known sequence replays only what was missed
    Given a client saw "t1" up to sequence 40
    When it subscribes to "t1" after sequence 40
    Then it receives only events after 40 and a completion marker

  # Dropped with a reason in parity/rpc.feature: no client subscribes to
  # orchestration.subscribeArchivedShell; archived threads come from getArchivedShellSnapshot.
  @node @dropped
  Scenario: Subscribing to the archived shell streams archive changes
    When a client subscribes to the archived shell
    And "t1" is archived
    Then the subscriber receives the archived row for "t1"

  @node
  Scenario: Methods the node does not serve are refused by name
    When a client calls "orchestration.getThreadProjection"
    Then it fails with "orchestration.getThreadProjection is not served by this node yet"
