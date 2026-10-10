# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/thread-sidebar.md (Inspect agent work: Limited, Resume at reset, Snooze until reset)
#   apps/web/src/components/ChatView.tsx (limit recovery)
#   apps/web/src/components/settings/SettingsPanels.tsx (Auto-resume limited threads, Snooze limited threads)
#   packages/contracts/src/orchestrationV2.ts (thread.metadata.update limitRecovery)
#   apps/server-ex/lib/hal_c2/projection/thread_error.ex (usageLimitResetAt)
#   apps/server-ex/lib/hal_c2/orchestration.ex (metadata.update limitRecovery)
#   apps/server-ex/lib/hal_c2/orchestration/limit_recovery.ex (arm and resume at the reset)
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

  @desktop @mobile @backlog-mobile
  Scenario: The conversation says the thread stopped on a usage limit
    Given "Port tests" stopped on a usage limit
    When the user opens "Port tests"
    Then the conversation says the thread stopped on a usage limit

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

  @mc @backlog
  Scenario: A rejected automatic resume keeps the reset time
    Given "Port tests" is scheduled to resume at 14:00
    When the provider rejects the automatic resume
    Then "Port tests" still records 14:00 as its reset time

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

  @mc
  Scenario: An overdue resume runs after a restart
    Given "Port tests" was scheduled to resume at 14:00
    And the environment was stopped from 13:00 until 15:00
    When the environment starts again
    Then "Port tests" continues

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

  @desktop @mobile @backlog-mobile
  Scenario: Agents without a reset time offer a manual retry
    Given the agent stopped "Port tests" on a limit without saying when it resets
    When the user opens "Port tests"
    Then the user can retry by hand or snooze with the usual choices

  @backlog @desktop @mobile
  Scenario: Continuing a limited thread on another agent
    Given "Port tests" stopped on a usage limit
    When the user switches "Port tests" to Codex and sends a message
    Then Codex continues the conversation

  @backlog @mobile
  Scenario: A reset time that has already passed cannot be snoozed until
    Given "Port tests" stopped on a usage limit that reset at 14:00
    And it is now 15:00
    When the user snoozes "Port tests" until the reset
    Then "Port tests" is not snoozed
    And the user is told the reset time has passed and to retry the thread by hand

  @backlog @mobile
  Scenario: A recovery choice that the environment refuses is reported on the thread
    Given "Port tests" stopped on a usage limit that resets at 14:00
    When the user chooses to resume at the reset and the environment refuses
    Then the user is told why the limit recovery could not be changed
    And "Port tests" is not scheduled to resume

  @backlog @mc
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
      | a message is queued on "Port tests"             |
      | the choice names a reset time other than 14:00  |

  @backlog @mc
  Scenario: A limit that had already reset when the agent stopped is never resumed on its own
    Given the user turned on auto-resume for limited threads
    When Claude stops "Port tests" at 14:05 on a usage limit that reset at 14:00
    Then "Port tests" is not scheduled to resume
    And it does not continue on its own

  @backlog @mc
  Scenario: The automatic resume is a message written by the server
    Given "Port tests" is scheduled to resume at 14:00
    When 14:00 passes
    Then "Port tests" receives the user message "Continue where you left off." written by the server
    And its turn starts at once

  @backlog @mc
  Scenario: A scheduled resume waits out a longer snooze the user set
    Given "Port tests" is scheduled to resume at 14:00
    And the user snoozed "Port tests" until 16:00
    When 14:00 passes
    Then "Port tests" does not continue
    And it continues on its own once the snooze ends at 16:00

  @backlog @mc
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

  @backlog @mc
  Scenario: Turning off snooze until reset leaves a snooze the user set by hand
    Given "Port tests" was snoozed until its limit resets at 14:00
    And the user then snoozed "Port tests" until 18:00
    When the user turns off snoozing until the reset for "Port tests"
    Then "Port tests" stays snoozed until 18:00

  # The other option is forgotten only when the choice is for a different stop or reset time.
  @backlog @mc
  Scenario: Changing one recovery option keeps the other for the same limit stop
    Given "Port tests" is scheduled to resume at 14:00
    When the user also snoozes "Port tests" until the reset without naming the resume option
    Then "Port tests" is snoozed until 14:00
    And it is still scheduled to resume at 14:00
