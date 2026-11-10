# Sources:
#   https://github.com/hal-c2/hal-c2/issues/483 (seeing a heavy run and the way to stop it)
#   https://github.com/hal-c2/hal-c2/issues/1482 (seeing a heavy run and stopping it)
#   apps/server-ex/lib/hal_c2/diagnostics.ex (process tree, resource history)
#   Shared domain: mc/platform/agent-containment.feature decides when a run is heavy;
#   mc/orchestration/runs.feature owns Stop and Force stop; settings/diagnostics.feature owns
#   the process list.
@backlog @shared
Feature: A run that uses a lot

  When the MC marks a thread's run as using a lot of CPU, memory or processes, every client says
  so where the user looks for the thread and offers the way to stop it.

  Background:
    Given "t1" is marked as using a lot of memory

  Scenario: The thread list shows a thread whose run uses a lot, until it calms down
    Then the thread list shows that "t1" is using a lot of memory
    When the mark on "t1" is cleared
    Then the thread list no longer does

  Scenario Outline: The thread says what its run uses and offers to stop it
    Given "t1" <state>
    When the user opens "t1"
    Then it says the run is using a lot of memory, and how much
    And it offers "<stop>"

    Examples:
      | state                                 | stop         |
      | has a running turn                    | Force stop   |
      | is idle with a dev server still going | Stop session |

  Scenario: Stopping a heavy run from where it is shown ends everything its agent started
    When the user stops the run of "t1" from where it is shown
    Then the agent of "t1" and everything it started end
    And the mark on "t1" is cleared
    And the next message to "t1" resumes its conversation in a fresh session

  Scenario: The command palette offers to stop a heavy run
    When the user looks for "stop" in the command palette while "t1" is open
    Then it offers to stop the run of "t1" that is using a lot of memory

  Scenario: Process diagnostics show which thread a process belongs to
    When the user opens the process diagnostics
    Then the agent of "t1" and the processes it started are listed under "t1"
