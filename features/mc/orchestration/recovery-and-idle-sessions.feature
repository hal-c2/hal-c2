# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (run.updated, run-attempt.updated, provider-turn.updated,
#     node.updated, turn-item.updated, message.updated, runtime-request.updated,
#     provider-thread.updated, provider-session.updated, queue.resume)
#   packages/contracts/src/settings.ts (continueThreadsAfterServerUpdate)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex
#   apps/server-ex/lib/hal_c2/orchestration/idle_sessions.ex
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (background subagents and commands, also between turns)
#   apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts (task_started, task_notification, pendingBackgroundTasks)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (commands left running in background terminals)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (settledTurns, terminalizeRunningCommandItems,
#     thread/backgroundTerminals/terminate, background command continuation)
#   apps/server/src/orchestration-v2/testkit/fixtures/turn_interrupt_mid_tool/codex_transcript.ndjson
#   apps/server-ex/lib/hal_c2/orchestration/limit_recovery.ex
#   apps/server-ex/config/runtime.exs (HAL_C2_MC_NO_AUTO_ACTIONS)
#   apps/server-ex/lib/hal_c2/orchestration/turn_watch.ex
#   apps/server/src/orchestration-v2/ (startup recovery, idle session reaper)
#   apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts (limit recovery at the reset time)
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2LimitRecovery)
#   docs/user/ (continuing threads after an update)
Feature: Recovering from restarts and releasing idle sessions
  Provider processes die with the MC. At boot the engine ends every turn that
  was cut off, so no thread is stuck running, and can ask cut-off threads to
  continue. While the MC runs, a turn whose runtime crashes ends as failed, and
  stopping a turn nothing drives any more ends it. The MC also stops provider
  processes that sat idle.

  Background:
    Given an MC with a project "demo"

  @mc
  Scenario: A turn cut off by a restart is interrupted at boot
    Given thread "t1" had a running turn with a streaming answer and a running command
    When the MC restarts
    Then the run, its attempt, its provider turn and its nodes are interrupted
    And the running command item is interrupted
    And the answer stops streaming
    And the provider thread of "t1" is idle

  @mc
  Scenario: A native subagent thread left running by a restart is settled
    Given a native provider subagent thread of "t1" was running when the MC stopped
    When the MC restarts
    Then the subagent thread is settled or interrupted
    And it is not left running

  @mc
  Scenario: Recovery happens before clients are served
    Given thread "t1" had a running turn
    When the MC restarts and a client connects
    Then the client never sees "t1" as running

  @mc
  Scenario: Only threads that showed an active run are opened at boot
    Given thread "t1" was idle and thread "t2" was running when the MC stopped
    When the MC restarts
    Then only "t2" is settled

  @mc
  Scenario: A settled thread continues when a restart ended its background work
    Given project "demo" continues threads after a server update
    And thread "t1" finished its turn and left a command running in the background
    When the MC restarts
    Then "t1" receives one continuation turn
    And the continuation names the background command the restart ended

  @mc
  Scenario: A cut-off thread continues after the restart when the project allows it
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn on a provider conversation that can resume
    When the MC restarts
    Then "t1" receives "Continue where you left off." from the server on the same model
    And it starts immediately

  @mc
  Scenario Outline: A cut-off thread is not continued
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn when the MC stopped
    And <reason>
    When the MC restarts
    Then no continuation message is sent to "t1"

    Examples:
      | reason                                                  |
      | the project does not continue threads after an update   |
      | "t1" is archived                                        |
      | "t1" is deleted                                         |
      | a newer message was sent to "t1" after that run         |
      | the run was waiting on the user rather than running     |
      | the provider conversation has no native thread to resume |

  # The runtime is the MC's process driving the provider; its provider process
  # goes down with it.
  @mc
  Scenario Outline: A turn whose runtime crashes ends as failed
    Given thread "t1" exists in "demo"
    And "t1" has a running turn on "<provider>" and a queued message "Next"
    When the runtime running the turn of "t1" crashes
    Then the run of "t1" fails saying the session ended unexpectedly
    And a run for "Next" starts

    Examples:
      | provider    |
      | codex       |
      | claudeAgent |
      | opencode    |

  # Nothing is left to interrupt, so the stop ends the run itself.
  @mc
  Scenario: Stopping a turn whose runtime is gone ends it
    Given thread "t1" exists in "demo"
    And "t1" has a running turn on "codex" and a queued message "Next"
    And the runtime running the turn of "t1" stops without ending it
    When the user stops "t1"
    Then the run of "t1" is interrupted
    And a run for "Next" starts

  @mc
  Scenario: Idle provider sessions are released after 30 minutes
    Given thread "t1" has a live provider process and no activity for 30 minutes
    When the MC checks for idle sessions
    Then the provider process of "t1" stops
    And its provider session is stopped

  @mc
  Scenario: A session with background tasks is kept for up to 4 hours
    Given thread "t1" has background tasks running and no activity for 1 hour
    When the MC checks for idle sessions
    Then the provider process of "t1" keeps running
    And it is released once 4 hours pass without activity

  @mc
  Scenario: A Claude background subagent keeps its session past the idle timeout
    Given thread "t1" left a Claude subagent and a command running in the background
    And "t1" has had no activity for 30 minutes
    When the MC checks for idle sessions
    Then the provider process of "t1" keeps running
    And "t1" lists the subagent and the command as background work

  @mc
  Scenario: A Claude session is released once its background work is done
    Given thread "t1" left a Claude subagent and a command running in the background
    When Claude reports the subagent completed with "3 files" and the command stopped
    And "t1" has had no activity for 30 minutes
    And the MC checks for idle sessions
    Then the provider process of "t1" stops
    And the subagent of "t1" is completed with "3 files"
    And "t1" lists no background work

  @mc
  Scenario Outline: Stopping or rewinding a Claude thread ends its background work
    Given thread "t1" left a Claude subagent and a command running in the background
    When the user <action>
    Then the subagent and the command of "t1" are interrupted
    And "t1" lists no background work

    Examples:
      | action                        |
      | stops "t1"                    |
      | rewinds "t1" to its first run |

  @mc
  Scenario Outline: A Claude subagent the MC first hears of between turns keeps its session
    Given thread "t1" finished a Claude turn
    When Claude <starts> between turns
    And "t1" has had no activity for 30 minutes
    And the MC checks for idle sessions
    Then the provider process of "t1" keeps running
    And "t1" lists the subagent "Check the tests" as background work
    When Claude reports that subagent completed
    Then "t1" lists no background work

    Examples:
      | starts                                    |
      | launches a subagent in the background     |
      | reports progress on a subagent it resumed |

  @mc @plugin-codex
  Scenario: A Codex background command keeps its session past the idle timeout
    Given thread "t1" left a Codex command running in the background
    And "t1" has had no activity for 30 minutes
    When the MC checks for idle sessions
    Then the provider process of "t1" keeps running
    And "t1" lists the command "npm run dev" as background work

  @mc @plugin-codex
  Scenario: A Codex session is released once its background command ends
    Given thread "t1" left a Codex command running in the background
    When Codex reports the command exited with "bye"
    And "t1" has had no activity for 30 minutes
    And the MC checks for idle sessions
    Then the provider process of "t1" stops
    And the command of "t1" is completed with "bye"
    And "t1" lists no background work

  @mc @plugin-codex
  Scenario Outline: Stopping or rewinding a Codex thread stops its background command
    Given thread "t1" left a Codex command running in the background
    When the user <action>
    Then the command of "t1" is interrupted
    And Codex is asked to terminate the command's terminal
    And "t1" lists no background work

    Examples:
      | action                        |
      | stops "t1"                    |
      | rewinds "t1" to its first run |

  # Codex leaves a unified exec process running when it interrupts a turn.
  @mc @plugin-codex
  Scenario: Stopping a Codex turn stops the command it started in a terminal
    Given thread "t1" has a Codex turn running a command in a terminal
    When the user stops "t1"
    Then the command of "t1" is interrupted
    And Codex is asked to terminate the command's terminal

  @mc @plugin-codex
  Scenario: A Codex background command fails when Codex exits
    Given thread "t1" left a Codex command running in the background
    When the Codex process of "t1" exits
    Then the command of "t1" is failed
    And "t1" lists no background work

  # Upstream offers Codex a continuation turn saying the command finished.
  @mc @plugin-codex
  Scenario: A finished Codex background command wakes the thread
    Given thread "t1" left a Codex command running in the background
    When Codex reports the command exited with "bye"
    Then "t1" runs a turn telling Codex the background command finished

  @mc
  Scenario: Background work a stopped MC left running is ended at boot
    Given thread "t1" had a Claude subagent and a command running in the background when the MC stopped
    When the MC restarts and a client connects
    Then the subagent and the command of "t1" are interrupted
    And "t1" lists no background work

  @mc
  Scenario Outline: A session that is still in use is never released
    Given thread "t1" has a live provider process and no activity for 2 hours
    And "t1" <state>
    When the MC checks for idle sessions
    Then the provider process of "t1" keeps running

    Examples:
      | state                            |
      | has an active run                |
      | waits on an approval or question |

  @mc
  Scenario: A provider process whose thread was deleted is released
    Given a provider process is live for a thread that was deleted
    When the MC checks for idle sessions
    Then that provider process stops

  @mc
  Scenario: The idle check runs every five minutes
    Given thread "t1" became idle 30 minutes ago
    When five minutes pass
    Then the provider process of "t1" has been released

  @mc
  Scenario: A released session starts again on the next message
    Given the idle session of "t1" was released
    When the user sends "Back" to "t1"
    Then the provider starts again and resumes its conversation

  # The check found the thread idle and the message reached the provider process first;
  # a provider process that took the turn instead keeps it.
  @mc
  Scenario: A message sent as its idle session is released still runs
    Given thread "t1" has a live provider process and no activity for 30 minutes
    When the MC releases the session of "t1" as the user sends "Back" to "t1"
    Then the provider starts again and resumes its conversation

  # The user-facing flow, cancelling and dropping a resume are in threads/limited-threads.feature.
  @mc
  Scenario: A thread stopped by a usage limit is resumed at the reset time
    Given the latest run of "t1" failed on a usage limit that resets at 14:00
    And "t1" records a limit recovery with auto-resume for that run and reset
    When 14:00 passes
    Then the engine continues "t1" once, without a new message from the user

  # A scratch MC on a copy of real data, as `mise run desktop:cua` starts one, names real checkouts.
  @mc
  Scenario: An MC without automatic actions resumes nothing at the reset time
    Given the MC runs without automatic actions
    And the latest run of "t1" failed on a usage limit that resets at 14:00
    And "t1" records a limit recovery with auto-resume for that run and reset
    When 14:00 passes
    Then nothing is sent to "t1"
