# Sources:
#   packages/contracts/src/orchestrationV2.ts (run.updated, run-attempt.updated, provider-turn.updated,
#     node.updated, turn-item.updated, message.updated, runtime-request.updated,
#     provider-thread.updated, provider-session.updated, queue.resume)
#   packages/contracts/src/settings.ts (continueThreadsAfterServerUpdate)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex
#   apps/server-ex/lib/hal_c2/orchestration/idle_sessions.ex
#   apps/server/src/orchestration-v2/ (startup recovery, idle session reaper)
#   apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts (limit recovery at the reset time)
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2LimitRecovery)
#   docs/user/ (continuing threads after an update)
Feature: Recovering from restarts and releasing idle sessions
  Provider processes die with the node. At boot the engine ends every turn that
  was cut off, so no thread is stuck running, and can ask cut-off threads to
  continue. While running it stops provider processes that sat idle.

  Background:
    Given a node with a project "demo"

  @node
  Scenario: A turn cut off by a restart is interrupted at boot
    Given thread "t1" had a running turn with a streaming answer and a running command
    When the node restarts
    Then the run, its attempt, its provider turn and its nodes are interrupted
    And the running command item is interrupted
    And the answer stops streaming
    And the provider thread of "t1" is idle

  @node
  Scenario: Recovery happens before clients are served
    Given thread "t1" had a running turn
    When the node restarts and a client connects
    Then the client never sees "t1" as running

  @node
  Scenario: Only threads that showed an active run are opened at boot
    Given thread "t1" was idle and thread "t2" was running when the node stopped
    When the node restarts
    Then only "t2" is settled

  @node
  Scenario: A cut-off thread continues after the restart when the project allows it
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn on a provider conversation that can resume
    When the node restarts
    Then "t1" receives "Continue where you left off." from the server on the same model
    And it starts immediately

  @node
  Scenario Outline: A cut-off thread is not continued
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn when the node stopped
    And <reason>
    When the node restarts
    Then no continuation message is sent to "t1"

    Examples:
      | reason                                                  |
      | the project does not continue threads after an update   |
      | "t1" is archived                                        |
      | "t1" is deleted                                         |
      | a newer message was sent to "t1" after that run         |
      | the run was waiting on the user rather than running     |
      | the provider conversation has no native thread to resume |

  @node
  Scenario: Idle provider sessions are released after 30 minutes
    Given thread "t1" has a live provider process and no activity for 30 minutes
    When the node checks for idle sessions
    Then the provider process of "t1" stops
    And its provider session is stopped

  @node
  Scenario: A session with background tasks is kept for up to 4 hours
    Given thread "t1" has background tasks running and no activity for 1 hour
    When the node checks for idle sessions
    Then the provider process of "t1" keeps running
    And it is released once 4 hours pass without activity

  @node
  Scenario Outline: A session that is still in use is never released
    Given thread "t1" has a live provider process and no activity for 2 hours
    And "t1" <state>
    When the node checks for idle sessions
    Then the provider process of "t1" keeps running

    Examples:
      | state                            |
      | has an active run                |
      | waits on an approval or question |

  @node
  Scenario: A provider process whose thread was deleted is released
    Given a provider process is live for a thread that was deleted
    When the node checks for idle sessions
    Then that provider process stops

  @node
  Scenario: The idle check runs every five minutes
    Given thread "t1" became idle 30 minutes ago
    When five minutes pass
    Then the provider process of "t1" has been released

  @node
  Scenario: A released session starts again on the next message
    Given the idle session of "t1" was released
    When the user sends "Back" to "t1"
    Then the provider starts again and resumes its conversation

  # The node stores a thread's limit recovery choice but nothing acts on it at the reset.
  # The user-facing flow, cancelling and dropping a resume are in threads/limited-threads.feature.
  @node @backlog
  Scenario: A thread stopped by a usage limit is resumed at the reset time
    Given the latest run of "t1" failed on a usage limit that resets at 14:00
    And "t1" records a limit recovery with auto-resume for that run and reset
    When 14:00 passes
    Then the engine continues "t1" once, without a new message from the user
