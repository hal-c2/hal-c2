# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/thread-sidebar.md (Inspect agent work: Limited, Resume at reset, Snooze until reset)
#   apps/web/src/components/ChatView.tsx (limit recovery)
#   apps/web/src/components/settings/SettingsPanels.tsx (Auto-resume limited threads, Snooze limited threads)
#   packages/contracts/src/orchestrationV2.ts (thread.metadata.update limitRecovery)
#   apps/server-ex/lib/hal_c2/projection/thread_error.ex (usageLimitResetAt)
#   apps/server-ex/lib/hal_c2/orchestration.ex (metadata.update limitRecovery)
#   apps/server-ex/lib/hal_c2/orchestration/limit_recovery.ex (arm and resume at the reset)

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
  Scenario: The conversation keeps the agent's explanation of the limit
    Given "Port tests" stopped on a usage limit
    When the user opens "Port tests"
    Then the agent's explanation of the limit is shown in the conversation

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
