# Sources:
#   https://github.com/hal-c2/hal-c2/issues/483 (containing an agent's processes)
#   https://github.com/hal-c2/hal-c2/issues/1480 (a scope per agent on Linux, ended with its session)
#   https://github.com/hal-c2/hal-c2/issues/1481 (agents' priority and limits)
#   https://github.com/hal-c2/hal-c2/issues/1482 (seeing a heavy run and stopping it)
#   https://github.com/hal-c2/hal-c2/issues/1483 (macOS)
#   https://github.com/hal-c2/hal-c2/issues/702 (macOS marks)
#   https://github.com/pingdotgg/t3code/pull/17662 (agent scopes and the agents slice)
#   https://github.com/pingdotgg/t3code/pull/21299 (a session's background work ends with it)
#   apps/server-ex/lib/hal_c2/subprocess.ex (owned and durable programs, stop)
#   apps/server-ex/lib/hal_c2/subprocess/orphans.ex (program records, marks, the boot kill)
#   apps/server-ex/lib/hal_c2/subprocess/durable.ex (survivors, the shim's watcher)
#   apps/server-ex/lib/hal_c2/diagnostics.ex (the 15-second sampler)
#   Shared domain: mc/platform/host-integration.feature holds upstream's scope, slice and
#   out-of-memory scenarios, and owns which endings stop an agent's scope ("An agent's
#   detached helpers end with it on Linux"); this file owns what Stop does to them; mc/orchestration/recovery-and-idle-sessions.feature holds the
#   boot kill by records and marks; threads/heavy-runs.feature holds what clients show.
Feature: Containing what an agent runs

  Every program an agent session runs, and everything it starts, is held together so it can be
  stopped as one, kept below the user's own work, and watched. On Linux that is a systemd scope
  per agent program, in a slice per MC home. Where there is no systemd user manager, and on
  macOS, the program's process group and the mark in its environment stand in for it.

  # hal-c2/hal-c2#483: background jobs belong to the session, which providers keep across
  # turns on purpose (dev servers, background shells), so Stop ends the turn and Force stop
  # ends the session. Blocked on the maintainer's answer to whether Stop should end them too;
  # this is the one scenario for Stop and detached jobs, so the answer changes only it.
  @backlog @blocked @mc
  Scenario: Stopping a turn leaves the session's background jobs running
    Given the MC runs on Linux under a systemd user manager
    And during a turn the agent of "t1" started a dev server in the background
    When the user stops the thread
    Then the turn ends and the command it was running ends
    And the dev server keeps running until the session of "t1" ends

  # The boot kills by scope first; the records and marks of recovery-and-idle-sessions.feature
  # stay as the fallback where there are no scopes.
  @backlog @mc @priority-high
  Scenario: Restarting the MC ends what agents left behind, except the sessions it takes back
    Given the MC runs on Linux under a systemd user manager
    And "t1" is mid-run on an agent the MC takes back when it restarts
    And the MC stopped while the agent of "t2", which it does not take back, ran a dev server
    When the MC restarts
    Then the agent of "t1" and everything it started keep running
    And the dev server of "t2" has been stopped before any thread resumes

  @backlog @mc
  Scenario: Two MCs on one machine do not stop each other's agents
    Given a development MC and an installed MC run on one Linux machine, each with its own home
    And each has a thread whose agent is working
    When the development MC restarts
    Then the installed MC's agent and everything it started keep running

  @backlog @mc @priority-low
  Scenario: An agent whose MC never comes back ends with everything it started
    Given the MC runs on Linux under a systemd user manager
    And an agent of "t1" that survives MC restarts started a dev server in a session of its own
    When the MC stops and does not come back for 10 minutes
    Then the agent and the dev server have ended

  # The way to see that containment is off, for a host without a user manager.
  @backlog @mc
  Scenario Outline: Process diagnostics say how agents are contained
    Given the MC runs <where>
    When the user reads the process diagnostics
    Then they say <containment>

    Examples:
      | where                                   | containment                                                     |
      | on Linux under a systemd user manager   | each agent runs in its own scope with the agents' limits        |
      | on Linux without a systemd user manager | agents run without a scope or limits, and why                   |
      | on macOS                                | agents are stopped by process group and run at a lower priority |

  # A terminal that hands the MC a raised priority hands it to every agent too.
  @backlog @mc
  Scenario Outline: Agents start below the user's own work whatever the MC's priority
    Given the MC runs <where> at a raised priority
    When a thread starts an agent
    Then the agent and everything it starts run at a lower priority than the user's applications

    Examples:
      | where                                   |
      | on Linux under a systemd user manager   |
      | on Linux without a systemd user manager |
      | on macOS                                |

  @backlog @mc
  Scenario Outline: A run that keeps using a lot is marked, and unmarked once it calms down
    Given the agent of "t1" and everything it started use <use>
    When that lasts for two samples in a row
    Then "t1" is marked as using a lot of <resource>, with how much
    When its use stays below that for two samples in a row
    Then the mark on "t1" is cleared

    Examples:
      | use                                          | resource  |
      | more than half of the machine's CPU          | CPU       |
      | more than a quarter of the machine's memory  | memory    |
      | more than a quarter of the agents' processes | processes |

  # Live numbers stay in process diagnostics; threads carry only the crossing.
  @backlog @mc
  Scenario: Clients hear about a run's resource use only when it crosses a threshold
    Given a client follows "t1"
    When the use of the agent of "t1" changes without crossing a threshold
    Then the client receives no update about "t1"'s resource use

  @backlog @mc
  Scenario Outline: Runs without a scope are measured by their processes
    Given the MC runs <where>
    And the agent of "t1" and everything it started use more than half of the machine's CPU
    When that lasts for two samples in a row
    Then "t1" is marked as using a lot of CPU, with how much

    Examples:
      | where                                   |
      | on Linux without a systemd user manager |
      | on macOS                                |

  @backlog @mc
  Scenario: Ending a session on macOS ends the background jobs its agent started
    Given the MC runs on macOS
    And the agent of "t1" started a dev server in the background
    When the user stops the session of "t1"
    Then the dev server ends with the agent of "t1"
