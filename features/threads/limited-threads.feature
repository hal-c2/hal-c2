# Sources:
#   https://github.com/pingdotgg/t3code/pull/27662
#   https://github.com/pingdotgg/t3code/pull/23803
#   https://github.com/pingdotgg/t3code/pull/21735
#   https://github.com/pingdotgg/t3code/pull/21114
#   https://github.com/pingdotgg/t3code/pull/22915
#   https://github.com/pingdotgg/t3code/pull/17457
#   https://github.com/pingdotgg/t3code/pull/17867
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/25005
#   https://github.com/pingdotgg/t3code/pull/24634
#   https://github.com/pingdotgg/t3code/pull/24697
#   docs/user/thread-sidebar.md (Inspect agent work: Limited, Resume at reset, Snooze until reset)
#   apps/web/src/components/ChatView.tsx (limit recovery)
#   apps/web/src/components/settings/SettingsPanels.tsx (Auto-resume limited threads, Snooze limited threads)
#   packages/contracts/src/orchestrationV2.ts (thread.metadata.update limitRecovery)
#   apps/server-ex/lib/hal_c2/projection/thread_error.ex (usageLimitResetAt)
#   apps/server-ex/lib/hal_c2/orchestration.ex (metadata.update limitRecovery)
#   apps/server-ex/lib/hal_c2/orchestration/limit_recovery.ex (arm and resume at the reset)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (a limit stop holds the queue behind it)
#   apps/mobile/src/features/threads/UsageLimitRecoveryCard.tsx (passed reset time, refused change)
#   apps/server/src/orchestration-v2/Orchestrator.ts (limit recovery refusals, snooze and resume choices)
#   apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts (resume message, expired resets)

Feature: Threads stopped by a usage limit
  When an agent stops on a usage or rate limit, the thread says so and the user decides
  whether to wait, continue later on its own, or switch agents.

  Background:
    Given a connected environment with the thread "Port tests" on Claude

  @mc
  Scenario: A thread stopped by a usage limit knows when the limit resets
    When Claude stops "Port tests" on a usage limit that resets at 14:00
    Then "Port tests" is marked as limited
    And its reset time is 14:00

  @desktop
  Scenario: A limited thread says so in the thread list
    Given "Port tests" stopped on a usage limit
    When the user looks at the thread list
    Then the row for "Port tests" reads "Limited"

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: The conversation says the thread stopped on a usage limit
    Given "Port tests" stopped on a usage limit
    When the user opens "Port tests"
    Then the conversation says the thread stopped on a usage limit

  # Upstream #22915: the composer's limit banner wrote the reset time in the system's long
  # form, ignoring Time format, while the timeline row above it followed it.
  @backlog @shared @priority-low
  Scenario: The reset time is written in the chosen time format
    Given the user set the time format to "24-hour"
    And "Port tests" stopped on a usage limit that resets tomorrow at 17:30
    When the user opens "Port tests"
    Then the composer says the limit resets tomorrow at 17:30

  @mc
  Scenario: Resuming at the reset time
    Given "Port tests" stopped on a usage limit that resets at 14:00
    When the user chooses to resume at the reset
    Then "Port tests" continues on its own at 14:00

  @mc
  Scenario: Cancelling a scheduled resume
    Given "Port tests" is scheduled to resume at 14:00
    When the user cancels the scheduled resume
    Then "Port tests" does not continue at 14:00

  @mc @priority-high
  Scenario: A rejected automatic resume keeps the reset time
    Given "Port tests" is scheduled to resume at 14:00
    When the provider rejects the automatic resume
    Then "Port tests" still records 14:00 as its reset time

  # Upstream #17867: Resume sends the composer's model selection with the continuation turn
  @backlog @shared @mobile
  Scenario: Resuming a limited thread uses the model picked in the composer
    Given "Port tests" stopped on a usage limit of its model
    And the user picked another model or account in the composer
    When the user resumes "Port tests"
    Then the thread continues on the picked model and account, not the limited one

  # Upstream #24697: switching threads while Resume saved its settings sent the other thread's model.
  @backlog @shared @priority-high
  Scenario: Resume keeps the model shown when it was pressed after the user switches threads
    Given "Port tests" on Claude Opus and "Tax rounding" on Codex are both open
    And resuming "Port tests" has to save a changed permission first
    When the user resumes "Port tests" and opens "Tax rounding" before the save returns
    Then "Port tests" continues on Claude Opus

  @mc
  Scenario Outline: A scheduled resume is dropped when the user moves on
    Given "Port tests" is scheduled to resume at 14:00
    When the user <action> before 14:00
    Then "Port tests" does not continue on its own

    Examples:
      | action                |
      | sends a new message   |
      | archives "Port tests" |
      | settles "Port tests"  |

  # Upstream #21114: a later recovery sweep revived a thread the user had stopped.
  @mc @priority-high
  Scenario: Stopping a limited thread cancels its automatic resume for good
    Given the user turned on auto-resume for limited threads
    And Claude stopped "Port tests" on a usage limit that resets at 14:00
    When the user stops "Port tests"
    Then "Port tests" does not continue on its own at 14:00, nor after a restart
    And the thread no longer shows a scheduled resume
    And a snooze the thread had is kept

  # Upstream #24634: a limit that landed just after Stop or task_cancel was still resumed at the reset.
  @mc @priority-high
  Scenario Outline: A usage limit that lands as the run is stopped is not resumed
    Given the user turned on auto-resume for limited threads
    And Claude is running "Port tests"
    When <who> stops "Port tests" and Claude reports a usage limit that resets at 14:00 as the run ends
    Then "Port tests" does not continue on its own at 14:00
    And the user can still choose to resume it at the reset

    Examples:
      | who                                        |
      | the user                                   |
      | the parent agent cancelling its task       |

  # A stop that cuts Claude off mid-reply or mid-tool is the user's stop, not a provider
  # failure, even when a usage limit was reported earlier in the run.
  @mc @priority-high
  Scenario Outline: A stop that cuts the run short after a usage limit is only a stop
    Given the user turned on auto-resume for limited threads
    And Claude is running "Port tests"
    When the user stops "Port tests" <where> after Claude reported a usage limit that resets at 14:00
    Then the run is shown as stopped, not failed
    And "Port tests" does not continue on its own at 14:00

    Examples:
      | where            |
      | mid-reply        |
      | during a tool    |

  # Upstream #21114: a stopped usage-limit thread no longer auto-resumes, so resuming it is an explicit choice.
  @shared @mc @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A stopped limited thread can be set to resume at the reset again
    Given the user stopped "Port tests" after it stopped on a usage limit that resets at 14:00
    When the user chooses to resume at the reset
    Then "Port tests" continues on its own at 14:00

  @mc
  Scenario: An overdue resume runs after a restart
    Given "Port tests" was scheduled to resume at 14:00
    And the environment was stopped from 13:00 until 15:00
    When the environment starts again
    Then "Port tests" continues

  # Upstream #21735: after an update, a recovery sweep armed and resumed threads whose limits had
  # reset days before; a reset more than 24 hours overdue is no longer freshly armed.
  @mc @priority-high
  Scenario: A limit stop days old is not freshly scheduled to resume
    Given the user turned on auto-resume for limited threads
    And Claude stopped "Port tests" on a usage limit that reset four days ago
    And no resume was ever scheduled for it
    When the environment starts again
    Then "Port tests" is not scheduled to resume
    But a limit stop whose reset passed an hour ago is still scheduled to resume

  @mc
  Scenario: Limit stops resume on their own when the user chose that
    Given the user turned on auto-resume for limited threads
    When Claude stops "Port tests" on a usage limit that resets at 14:00
    Then "Port tests" is scheduled to resume at 14:00

  @desktop @mobile @backlog-mobile
  Scenario: Snoozing a limited thread until its reset
    Given "Port tests" stopped on a usage limit that resets at 14:00
    When the user snoozes "Port tests" until the reset
    Then "Port tests" is snoozed until 14:00
    And it wakes without sending a message

  # Upstream #17457: a failed resume or snooze says why without hiding the limit notice.
  @backlog @desktop @priority-low
  Scenario Outline: A recovery from a usage limit that fails says why and keeps the notice readable
    Given "Port tests" stopped on a usage limit that resets at 14:00
    When the user asks to <recover> and that fails
    Then the user is told why
    And the limit notice still shows its title and the reset time

    Examples:
      | recover                             |
      | resume "Port tests" at the reset    |
      | snooze "Port tests" until the reset |

  @desktop @mobile @backlog-mobile
  Scenario: Snoozing and auto-resume together wake and continue the thread
    Given the user turned on auto-resume and snoozing for limited threads
    When Claude stops "Port tests" on a usage limit that resets at 14:00
    Then at 14:00 "Port tests" wakes and continues

  @desktop @mobile @backlog-mobile
  Scenario: Waking a limited thread early
    Given "Port tests" is snoozed until its limit resets
    When the user wakes "Port tests" now
    Then "Port tests" is active again

  # Upstream #23803: with snooze and auto-resume armed for one reset, the limit notice offered
  # only "Cancel auto-resume".
  @backlog @desktop
  Scenario: The limit notice offers to wake a thread snoozed and set to resume
    Given "Port tests" is snoozed until its limit resets at 14:00 and set to resume then
    Then the limit notice offers "Wake now" beside "Cancel auto-resume"
    When the user chooses "Wake now"
    Then "Port tests" is active again and still resumes at 14:00

  @desktop @mobile @backlog-mobile
  Scenario: Agents without a reset time offer a manual retry
    Given the agent stopped "Port tests" on a limit without saying when it resets
    When the user opens "Port tests"
    Then the user can retry by hand or snooze with the usual choices

  # Upstream #27662: the phone's Resume only resumed the queue, which the server refuses while the
  # limit holds it, and the refusal was only logged.
  @backlog @shared
  Scenario: Resuming a limited thread continues it before its queue
    Given the agent stopped "Port tests" on a limit without saying when it resets
    And "also update the changelog" is queued behind the limit
    When the user resumes the thread
    Then "Port tests" continues where it left off
    And "also update the changelog" runs after it

  # Upstream #27662: the phone offered Resume only when the queue was held.
  @backlog @shared
  Scenario: A limited thread with nothing queued can be resumed
    Given the agent stopped "Port tests" on a limit without saying when it resets
    And nothing is queued in "Port tests"
    Then the user is offered "Resume thread"
    When the user resumes the thread
    Then "Port tests" continues where it left off

  # Upstream #27662: the phone saves composer modes to the thread before continuing.
  @backlog @shared
  Scenario: Resuming carries a mode the user changed in the composer
    Given "Port tests" stopped on a usage limit
    And the user switched the composer of "Port tests" to plan mode
    When the user resumes the thread
    Then "Port tests" continues in plan mode

  # Upstream #27662: the phone shows a failed continue or resume in a dialog.
  @backlog @shared
  Scenario: A resume that fails is shown once
    Given "Port tests" stopped on a usage limit
    And the environment refuses to continue "Port tests"
    When the user resumes the thread
    Then the user is told once why it could not continue

  @backlog @desktop @mobile
  Scenario: Continuing a limited thread on another agent
    Given "Port tests" stopped on a usage limit
    When the user switches "Port tests" to Codex and sends a message
    Then Codex continues the conversation

  @backlog @mobile @priority-low
  Scenario: A reset time that has already passed cannot be snoozed until
    Given "Port tests" stopped on a usage limit that reset at 14:00
    And it is now 15:00
    When the user snoozes "Port tests" until the reset
    Then "Port tests" is not snoozed
    And the user is told the reset time has passed and to retry the thread by hand

  # Upstream #25005: a reset more than about 25 days away never stopped offering the snooze
  # once it passed, because the timer for it was never armed.
  @backlog @desktop @mobile @priority-low
  Scenario: Snoozing until a reset weeks away stops being offered when that reset passes
    Given "Port tests" stopped on a usage limit that resets in 30 days
    And the limit notice is left open
    When the reset time passes
    Then the notice no longer offers to snooze "Port tests" until the reset

  @backlog @mobile
  Scenario: A recovery choice that the environment refuses is reported on the thread
    Given "Port tests" stopped on a usage limit that resets at 14:00
    When the user chooses to resume at the reset and the environment refuses
    Then the user is told why the limit recovery could not be changed
    And "Port tests" is not scheduled to resume

  @mc
  Scenario Outline: A recovery choice is refused once the limit stop is no longer current
    Given "Port tests" stopped on a usage limit that resets at 14:00
    And <change>
    When the user chooses to resume at the reset
    Then the choice is refused with "The provider limit changed before recovery could be configured."
    And "Port tests" is not scheduled to resume

    Examples:
      | change                                          |
      | a newer turn has run on "Port tests" since      |
      | "Port tests" is archived                        |
      | the user settled "Port tests"                   |
      | "Port tests" is waiting on an approval          |
      | the choice names a reset time other than 14:00  |

  # A limit stop holds the messages queued behind it, since they would only hit the same
  # limit. They do not stand in the way of a recovery choice, and the resume starts them
  # in order instead of writing a message of its own.
  @mc
  Scenario: Resuming at the reset with a message queued behind the limit
    Given "Port tests" stopped on a usage limit that resets at 14:00 with "also update the changelog" queued behind it
    When the user chooses to resume at the reset
    Then "Port tests" is scheduled to resume at 14:00
    And at 14:00 "Port tests" starts "also update the changelog" without writing a message of its own

  @mc
  Scenario: Snoozing until the reset with a message queued behind the limit
    Given "Port tests" stopped on a usage limit that resets at 14:00 with "also update the changelog" queued behind it
    When the user chooses to snooze "Port tests" until the reset
    Then "Port tests" is snoozed until the reset at 14:00
    And "also update the changelog" stays queued until the user resumes the queue

  @mc @priority-high
  Scenario: A limit that had already reset when the agent stopped is never resumed on its own
    Given the user turned on auto-resume for limited threads
    When Claude stops "Port tests" at 14:05 on a usage limit that reset at 14:00
    Then "Port tests" is not scheduled to resume
    And it does not continue on its own

  @mc
  Scenario: The automatic resume is a message written by the server
    Given "Port tests" is scheduled to resume at 14:00
    When 14:00 passes
    Then "Port tests" receives the user message "Continue where you left off." written by the server
    And its turn starts at once

  @mc
  Scenario: A scheduled resume waits out a longer snooze the user set
    Given "Port tests" is scheduled to resume at 14:00
    And the user snoozed "Port tests" until 16:00
    When 14:00 passes
    Then "Port tests" does not continue
    And it continues on its own once the snooze ends at 16:00

  @mc @priority-high
  Scenario Outline: A scheduled resume is not sent when the thread changed underneath it
    Given "Port tests" is scheduled to resume at 14:00
    And <change> before 14:00
    When 14:00 passes
    Then "Port tests" does not continue on its own

    Examples:
      | change                                          |
      | the user switched "Port tests" to another agent |
      | "Port tests" started waiting on an approval     |
      | the user deleted "Port tests"                   |

  @mc @priority-low
  Scenario: Turning off snooze until reset leaves a snooze the user set by hand
    Given "Port tests" was snoozed until its limit resets at 14:00
    And the user then snoozed "Port tests" until 18:00
    When the user turns off snoozing until the reset for "Port tests"
    Then "Port tests" stays snoozed until 18:00

  # The other option is forgotten only when the choice is for a different stop or reset time.
  @mc
  Scenario: Changing one recovery option keeps the other for the same limit stop
    Given "Port tests" is scheduled to resume at 14:00
    When the user also snoozes "Port tests" until the reset without naming the resume option
    Then "Port tests" is snoozed until 14:00
    And it is still scheduled to resume at 14:00
