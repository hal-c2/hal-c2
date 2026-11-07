# Sources:
#   https://github.com/pingdotgg/t3code/pull/20306
#   https://github.com/pingdotgg/t3code/pull/12513
#   https://github.com/pingdotgg/t3code/pull/19291
#   https://github.com/pingdotgg/t3code/pull/18461
#   https://github.com/pingdotgg/t3code/pull/16917 (covered: an idle Codex thread's session is released; background work keeps it)
#   https://github.com/pingdotgg/t3code/pull/19750
#   https://github.com/pingdotgg/t3code/pull/17715
#   https://github.com/pingdotgg/t3code/pull/17223
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (run.updated, run-attempt.updated, provider-turn.updated,
#     node.updated, turn-item.updated, message.updated, runtime-request.updated,
#     provider-thread.updated, provider-session.updated, queue.resume)
#   packages/contracts/src/settings.ts (continueThreadsAfterServerUpdate)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex
#   apps/server-ex/lib/hal_c2/orchestration/idle_sessions.ex
#   apps/server-ex/lib/hal_c2/subprocess/orphans.ex
#   https://github.com/hal-c2/hal-c2/issues/254 (provider CLIs left running by an MC that died)
#   https://github.com/hal-c2/hal-c2/issues/451 (tracking set up late, reaping first)
#   https://github.com/hal-c2/hal-c2/issues/380 (commands a provider that already exited left in its group)
#   https://github.com/hal-c2/hal-c2/issues/387 (commands in a session of their own outlive that kill)
#   https://github.com/hal-c2/hal-c2/issues/411 (a pid reused between the check and the kill)
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (background subagents and commands, also between turns)
#   https://github.com/hal-c2/hal-c2/issues/474 (a stop naming an earlier run ended what a later run left)
#   apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts (task_started, task_notification, pendingBackgroundTasks)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (commands left running in background terminals)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (settledTurns, terminalizeRunningCommandItems,
#     thread/backgroundTerminals/terminate, background command continuation)
#   apps/server/src/orchestration-v2/testkit/fixtures/turn_interrupt_mid_tool/codex_transcript.ndjson
#   apps/server-ex/lib/hal_c2/orchestration/limit_recovery.ex
#   apps/server-ex/config/runtime.exs (HAL_C2_MC_NO_AUTO_ACTIONS)
#   apps/server-ex/lib/hal_c2/orchestration/turn_watch.ex
#   apps/server/src/orchestration-v2/ (startup recovery, idle session reaper)
#   apps/server/src/orchestration-v2/ProviderRuntimeRecoveryService.ts (shutdown reconciliation, runs
#     waiting on a checkpoint)
#   apps/server/src/orchestration-v2/ProviderContinuationService.ts (wake messages, retries, dropped wakes)
#   apps/server/src/orchestration-v2/ProviderSessionManager.ts (close time limit, sessions shared by threads)
#   apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts (limit recovery at the reset time)
#   apps/server/src/orchestration-v2/RestartContinuation.ts (which cut-off turns are continued, once)
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2LimitRecovery)
#   docs/user/ (continuing threads after an update)
#   https://github.com/pingdotgg/t3code/pull/15323
#   https://github.com/pingdotgg/t3code/pull/15604
Feature: Recovering from restarts and releasing idle sessions
  Provider processes that cannot go on through a restart (reattach-after-restart.feature)
  are killed at the next boot, before any thread goes on. At boot the engine ends
  every turn that was cut off, so no thread is stuck running, and can ask cut-off
  threads to continue. While the MC runs, a turn whose runtime crashes ends as failed, and
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
  Scenario: A provider process an MC that died left running is killed at its next boot
    Given a provider process with a command in the background was running when the MC died
    When the MC restarts
    Then the provider process and its background command have been killed

  # hal-c2/hal-c2#451: a program is refused while it could not be found again, and a
  # moment's failure ends with the moment. What the boot could not reap goes first.
  @mc
  Scenario: Programs refused because tracking could not be set up at boot run once it can be
    Given a provider process with a command in the background was running when the MC died
    And the MC restarted unable to make the directory of its program records
    Then a program start is refused
    When the directory of program records can be made again
    And a program starts
    Then the provider process and its background command have been killed

  # hal-c2/hal-c2#387: a command that started a session or group of its own has left
  # the provider's process group, so the boot goes by the mark it still carries.
  @mc
  Scenario: A command a dead MC's provider ran in a session of its own is killed at the next boot
    Given a provider process with a command in a session of its own was running when the MC died
    When the MC restarts
    Then the provider process and its background command have been killed

  # hal-c2/hal-c2#380: with no leader to check the group against, the boot goes by
  # the mark in the commands' environment, which macOS gives it no way to read.
  @mc
  Scenario: A command left in the group of a provider that already exited is killed at the next boot
    Given a provider process had exited leaving a command in its group when the MC died
    When the MC restarts
    Then the provider process and its background command have been killed

  @mc
  Scenario: A native subagent thread left running by a restart is settled
    Given a native provider subagent thread of "t1" was running when the MC stopped
    When the MC restarts
    Then the subagent thread is settled or interrupted
    And it is not left running

  @mc
  Scenario: Work cut off by a restart says the restart ended it
    Given thread "t1" had a running turn with a running command
    When the MC restarts
    Then the command says it was cancelled because the server restarted before the provider work completed

  @mc
  Scenario: A clean shutdown ends running turns before the MC stops
    Given thread "t1" has a running turn with a running command
    When the MC shuts down cleanly
    Then the run and the command are ended before the MC stops
    And the command says it was cancelled because the server shut down before the provider work completed

  @mc
  Scenario: A turn that had finished but not yet captured its checkpoint is not cut off
    Given the provider turn of "t1" had ended and its checkpoint was still to be captured when the MC stopped
    When the MC restarts
    Then the run is not ended as cut off
    And it completes once its checkpoint is captured

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

  # Upstream #19291: a run that ended to wait on a monitor or subagent never woke after an update,
  # and its delegating parent took the interim message as the result.
  @mc @priority-high
  Scenario Outline: A run that ended to wait on work the restart stopped is continued
    Given project "demo" continues threads after a server update
    And thread "t1" ended its turn to wait on <work>
    When the MC restarts
    Then "t1" receives one continuation turn
    And the continuation names <work> the restart ended

    Examples:
      | work                  |
      | a monitor             |
      | a subagent            |
      | a background task     |

  # Upstream #19291. A continuation keeps the task working until it ends (see "A restart does not
  # report a delegated child's interrupted result as final"); with none, the
  # interim message is not the task's result.
  @mc @priority-high
  Scenario Outline: A task whose child waited on work the restart stopped is not completed by it
    Given thread "parent" has a running turn on "codex" in worktree "/work/p"
    And a task delegated to "t1" ended its turn to wait on <work>
    When the MC restarts
    Then the task delegated to "t1" ends "interrupted", not "completed"

    Examples:
      | work                  |
      | a monitor             |
      | a subagent            |
      | a background task     |

  @backlog @mc
  Scenario: A shutdown releases every provider session at once
    Given ten threads have provider sessions open
    When the MC shuts down cleanly
    Then the sessions are released side by side, not one after another
    And none is left running for the next MC to resume beside it

  # Upstream #12513: helpers that ignored SIGTERM hung shutdown and survived the backend;
  # they are now killed a second after the stop request.
  @backlog @mc
  Scenario: A helper process that ignores the stop request does not outlive the MC
    Given a provider's helper process ignores the request to stop
    When the MC shuts down
    Then the helper is killed a second after it was asked to stop
    And the MC finishes shutting down

  # The boot kills what a dead MC's records name before it takes requests
  # (`HalC2.Subprocess.Orphans`); a process no MC recorded is not its to stop.
  @mc @priority-high
  Scenario: Agents a killed MC left running are stopped before new ones start
    Given an MC was killed while its agents were still running
    When a new MC on the same files launches its first agent
    Then the agents the killed MC left are stopped first
    And terminals the user started are left alone

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

  @mc
  Scenario: A thread switched to another provider since its cut-off turn is not continued
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn on "codex" when the MC stopped
    And "t1" is now set to run on "claudeAgent"
    When the MC restarts
    Then no continuation message is sent to "t1"

  @mc
  Scenario: A continuation cut off by a second restart before its agent started is sent on
    Given project "demo" continues threads after a server update
    And the continuation turn of "t1" had not reached its provider when the MC stopped again
    When the MC restarts
    Then "t1" is continued from that turn

  @mc
  Scenario: A cut-off turn is continued only once
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn on a provider conversation that can resume
    When the MC restarts and its recovery runs twice for "t1"
    Then "t1" receives one "Continue where you left off." message

  # Upstream #18461: a turn that crashed the server was otherwise resumed after every restart.
  @mc
  Scenario: A thread is continued at most three times in a row without the user
    Given project "demo" continues threads after a server update
    And "t1" has been continued after 3 restarts in a row without a message from the user
    And thread "t1" was mid-turn on a provider conversation that can resume
    When the MC restarts
    Then no continuation message is sent to "t1"
    And "t1" waits for the user's next message
    When the user sends "Try again" to "t1"
    Then "t1" may be continued after a later restart again

  # Upstream #20306: the restart guard counts only continuations requested within five minutes
  # of the interrupted run finishing; rapid loops still stop at three.
  @mc
  Scenario: Continuations far apart do not use up the restart limit
    Given project "demo" continues threads after a server update
    And "t1" has been continued after 3 restarts, each after more than five minutes of work
    And thread "t1" was mid-turn on a provider conversation that can resume
    When the MC restarts
    Then "t1" receives "Continue where you left off." from the server

  @backlog @mc
  Scenario Outline: A cut-off thread that should not be answered for is not continued
    Given project "demo" continues threads after a server update
    And thread "t1" was mid-turn when the MC stopped
    And <reason>
    When the MC restarts
    Then no continuation message is sent to "t1"

    Examples:
      | reason                                                         |
      | the restart closed an approval "t1" was waiting on             |
      | the restart closed a question "t1" was asking the user         |
      | the restart closed a request for a secret from "t1"            |
      | the provider's turn had already ended                          |
      | "t1" is settled                                                |
      | "t1" is snoozed until tomorrow                                 |

  @mc
  Scenario: A continuation is checked again when it is delivered
    Given project "demo" continues threads after a server update
    And the continuation of "t1" was recorded but not yet delivered
    When "t1" is archived before it is delivered
    Then no continuation message is sent to "t1"

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

  @backlog @mc @plugin-claude
  Scenario: A Claude workflow that keeps reporting progress outlives the background cap
    Given thread "t1" left a Claude workflow running in the background
    And the workflow reports progress at least once every hour
    When four hours have passed since the turn ended
    And the MC checks for idle sessions
    Then the provider process of "t1" keeps running
    And "t1" lists the workflow as background work

  @backlog @mc @plugin-claude
  Scenario: A Claude workflow silent for the whole background cap is stopped
    Given thread "t1" left a Claude workflow running in the background
    And the workflow has reported nothing for four hours
    When the MC checks for idle sessions
    Then the provider process of "t1" stops

  @backlog @mc
  Scenario: Stopping a thread settles its native subagents' own threads
    Given thread "t1" has a provider-native subagent running with its own thread
    When the user stops "t1"
    Then the subagent reads as stopped, not running, and its timer stops
    And the subagent's thread no longer shows a working turn

  @backlog @mc
  Scenario: A restart settles a native subagent the stop left running
    Given thread "t1" was stopped while its native subagent's record still read as running
    When the MC restarts
    Then the subagent and its thread read as stopped

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

  # A restart reads the run it stops before that run ends; by the time the stop
  # arrives a later run may have left work running that is not the restart's to end.
  @mc
  Scenario: A stop naming an earlier run leaves the Claude work a later run left
    Given thread "t1" left a Claude subagent and a command running in the background
    When a client stops run 1 of "t1"
    Then the stop is refused
    And "t1" lists the subagent and the command as background work
    When a client stops run 2 of "t1"
    Then the subagent and the command of "t1" are interrupted

  @mc @plugin-codex
  Scenario: A stop naming an earlier run leaves the Codex command a later run left
    Given thread "t1" left a Codex command running in the background
    When a client stops run 1 of "t1"
    Then the stop is refused
    And "t1" lists the command "npm run dev" as background work
    When a client stops run 2 of "t1"
    Then the command of "t1" is interrupted

  # The client's stop names the thread's latest run, wherever it ran.
  @mc @plugin-codex
  Scenario: A stop naming a later run on Claude ends the Codex command an earlier run left
    Given thread "t1" left a Codex command running in the background
    And "t1" ran its latest turn on Claude
    When a client stops run 3 of "t1"
    Then the command of "t1" is interrupted
    And Codex is asked to terminate the command's terminal

  # Stopping a running turn ends only that turn, as it does on one provider. The next
  # stop comes between turns and ends the work an earlier run left.
  @mc @plugin-codex
  Scenario: A stop of a Claude turn leaves the Codex command an earlier run left
    Given thread "t1" left a Codex command running in the background
    And "t1" is running its latest turn on Claude
    When a client stops run 3 of "t1"
    Then run 3 of "t1" is interrupted
    And "t1" lists the command "npm run dev" as background work
    When a client stops run 3 of "t1"
    Then the command of "t1" is interrupted

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

  @mc @plugin-codex
  Scenario Outline: A Codex background command's wake says how the command ended
    Given thread "t1" left the Codex command "npm run dev" running in the background
    When Codex reports the command ended <ending>
    Then the wake of "t1" is marked <outcome> and reads "<summary>"
    And its turn tells Codex "<told>"

    Examples:
      | ending               | outcome   | summary                               | told                                               |
      | with exit code 0     | completed | Background command finished           | Background command completed (exit 0): npm run dev |
      | with exit code 2     | failed    | Background command exited with code 2 | Background command completed (exit 2): npm run dev |
      | without an exit code | unknown   | Background command finished           | Background command completed: npm run dev          |

  @mc @plugin-codex
  Scenario: A Codex background command's wake carries the end of its output
    Given thread "t1" left a Codex command running in the background
    When the command ends after writing 5,000 characters of output
    Then Codex is told the command ended, followed by "Output tail:" and the last 1,000 characters
    And a command line longer than 200 characters is cut there and ends with "..."

  @mc @plugin-codex
  Scenario: A Codex background command wakes the thread once
    Given thread "t1" left a Codex command running in the background
    When Codex reports the command ended twice
    Then "t1" runs one turn for it

  @mc @plugin-codex
  Scenario Outline: A Codex command that ends without having been left running wakes nothing
    Given thread "t1" has a Codex command <situation>
    When the command ends
    Then no turn starts in "t1" for it

    Examples:
      | situation                               |
      | still running inside its own turn       |
      | left running by a turn the user stopped |
      | left running by a turn that failed      |
      | left running by a subagent              |

  @mc @plugin-codex
  Scenario: A Codex background command that will not end fails the stop
    Given thread "t1" left a Codex command running in the background
    When the user stops "t1" and Codex still lists the command's terminal after being asked to end it
    Then the stop fails saying the background terminal remained active after termination

  @mc
  Scenario: A wake for finished background work waits behind the running turn
    Given thread "t1" has a running turn and work left running in the background
    When the provider reports the background work finished
    Then "t1" gets one message from the agent reading "Background task completed."
    And it runs after the running turn

  @mc
  Scenario: A wake that cannot be delivered is tried again
    Given thread "t1" left work running in the background
    When the work finishes and the wake cannot be delivered at first
    Then the MC tries again, waiting 100 milliseconds at first and never more than 5 seconds between tries
    And "t1" is woken once

  @mc
  Scenario Outline: A wake for a thread the user put away is dropped
    Given thread "t1" left work running in the background and was then <state>
    When the work finishes
    Then no turn starts in "t1"

    Examples:
      | state    |
      | archived |
      | deleted  |

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
  Scenario: A provider process that will not close is still released
    Given the provider process of "t1" does not exit when it is asked to
    When the session of "t1" is released
    Then the session is recorded as stopped after at most 30 seconds
    And "t1" can take its next message

  # Blocked on hal-c2/hal-c2#904: each MC thread has a provider session of its own, and a
  # provider's native subagents are entities of their parent thread, so no session has
  # several threads to serve. Carry upstream's attached-threads sessions, or drop these.
  @backlog @blocked @mc
  Scenario: A session serving several threads stays until the last one leaves
    Given one provider session serves thread "t1" and a subagent thread of "t1"
    When the subagent thread leaves the session while its turn is running
    Then only the subagent thread's turn is interrupted
    And the provider process keeps running for "t1"

  # Blocked on hal-c2/hal-c2#904: each MC thread has a provider session of its own, and a
  # provider's native subagents are entities of their parent thread, so no session has
  # several threads to serve. Carry upstream's attached-threads sessions, or drop these.
  @backlog @blocked @mc
  Scenario: A provider that serves one thread per session refuses a second thread
    Given a provider whose sessions serve one thread each has a session for "t1"
    When another thread is attached to that session
    Then it fails saying the provider does not support attaching multiple app threads to one session

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

  # Upstream #15323: a child the restart interrupted reported that as its result before its
  # continuation ran.
  @mc @priority-high
  Scenario: A restart does not report a delegated child's interrupted result as final
    Given project "demo" continues threads after a server update
    And thread "parent" has a running turn on "codex" in worktree "/work/p"
    And the agent in "parent" delegates a task
    And the continuation a restart asks of the subagent waits to be sent
    When the MC restarts
    Then the task is "running" however often it is checked while the continuation waits
    When the continuation is sent
    Then the task, its node and its turn item end "completed"

  # Upstream #15323: a restart continued a run the user had stopped and started the queue held behind it.
  @mc @priority-high
  Scenario: A restart keeps queued work waiting and work the user stopped stopped
    Given project "demo" continues threads after a server update
    And the user had asked to stop the running turn of "t1", with a message queued behind it
    When the MC restarts
    Then no continuation is asked of "t1"
    And the message queued on "t1" is held for the user

  @mc
  Scenario: A turn the user had asked to stop is not continued after a restart
    Given project "demo" continues threads after a server update
    And the user had asked to stop the running turn of "t1"
    When the MC restarts
    Then no continuation is asked of "t1"

  # Upstream #15604: a thread whose session the idle release had stopped is not woken for
  # the stale background records it left; the next turn the user starts hears what ended.
  @mc @priority-high
  Scenario: A settled thread stays asleep after a restart
    Given project "demo" continues threads after a server update
    And a completed thread has leftover background tool or subagent records
    When the MC restarts
    Then the thread is not woken
    And its background cleanup note reaches the provider once, on the next manual turn

  # Upstream #19750: work a subagent started belongs to that subagent, so losing it leaves
  # the parent waiting on the subagent. The note names the subagent to resume.
  @backlog @mc @plugin-claude
  Scenario: A restart that cut a Claude subagent's background command wakes the thread
    Given "continue threads after restarts" is on
    And a background Claude subagent of "t1" started a background command and ended its turn
    And "t1" ended its turn waiting on the subagent
    When the MC restarts and the command could not be kept
    Then "t1" is continued with a note naming the subagent by its id
    And the note says the work will not report back on its own and should be resumed and awaited

  @backlog @mc @plugin-codex
  Scenario: A turn cut by a restart is told which native subagents it was waiting on
    Given "continue threads after restarts" is on
    And a running Codex turn of "t1" was waiting on a native subagent
    When the MC restarts and the turn could not be kept
    Then the continuation of "t1" names the subagent by its own thread id
    And says it will not report back on its own

  @backlog @mc
  Scenario: A wake that never started does not hide the run that lost the work
    Given "continue threads after restarts" is on
    And a wake of "t1" was still starting when the MC stopped, after a settled run whose background work was lost
    When the MC restarts
    Then "t1" is continued from the settled run that lost the work
