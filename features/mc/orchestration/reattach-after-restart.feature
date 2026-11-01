# Sources:
#   apps/server-ex/lib/hal_c2/subprocess.ex (Exile stops a program with its owner, not with the VM)
#   apps/server-ex/lib/hal_c2/subprocess/orphans.ex (the records a boot reads, the kill this falls back to)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex (what a boot does to a turn it could not reattach)
#   apps/server-ex/lib/hal_c2/claude/session.ex, apps/server-ex/lib/hal_c2/claude/protocol.ex
#   apps/server-ex/lib/hal_c2/json_rpc/connection.ex (Codex, the ACP agents)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex, apps/server-ex/lib/hal_c2/acp/thread_runtime.ex
#   apps/server-ex/lib/hal_c2/pi/thread_runtime.ex, apps/server-ex/lib/hal_c2/muse/thread_runtime.ex
#   https://github.com/hal-c2/hal-c2/issues/254 (a resume beside a program still working)
#
# A program started without durability, as every scenario of
# recovery-and-idle-sessions.feature's is, still dies at the next boot.

@mc
Feature: Reattaching to provider programs after a restart
  On Unix-like systems a provider program outlives the MC that started it, and the next
  MC connects to it again, so a restart does not cost the agent its work. A program that
  cannot be reattached is killed and its turn is interrupted, as it is without this.

  Background:
    Given an MC with a project "demo"

  Rule: A turn goes on through a restart

    Scenario Outline: A turn running when the MC stopped goes on, on the same program
      Given thread "t1" has a running turn on "<provider>"
      When the MC <stops>
      And the MC restarts
      Then the provider process of "t1" is the one that was running
      And the run of "t1" is still running
      And no continuation message is sent to "t1" after reattaching

      Examples:
        | provider    | stops      |
        | codex       | dies       |
        | codex       | shuts down |
        | claudeAgent | dies       |
        | claudeAgent | shuts down |
        | cursor      | dies       |
        | cursor      | shuts down |
        | grok        | dies       |
        | grok        | shuts down |
        | opencode    | dies       |
        | opencode    | shuts down |
        | antigravity | dies       |
        | antigravity | shuts down |
        | pi          | dies       |
        | pi          | shuts down |
        | muse        | dies       |
        | muse        | shuts down |
        | acpRegistry | dies       |
        | acpRegistry | shuts down |

    # Stopping crosses to the program, and its answer comes back from it. ACP's answer is
    # to a prompt the earlier MC sent, so it is also the reply that outlived its caller.
    Scenario Outline: A reattached turn answers its stop
      Given thread "t1" has a running turn on "<provider>"
      When the MC dies
      And the MC restarts
      And the user stops "t1" after the restart
      Then the run of "t1" is interrupted

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

  Rule: A program that cannot be reattached falls back to the kill

    Scenario Outline: A program with no usable checkpoint is killed before anything resumes
      Given thread "t1" has a running turn on "<provider>"
      When the MC dies
      And the snapshot of "t1" is unreadable
      And the MC restarts
      Then that provider process has been killed
      And the run of "t1" is interrupted

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    Scenario Outline: A program that ended while the MC was down ends its turn
      Given thread "t1" has a running turn on "<provider>"
      When the MC dies
      And the provider process of "t1" exits while the MC is down
      And the MC restarts
      Then the run of "t1" ended without a second program

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    Scenario: A client never sees a reattached turn as ended
      Given thread "t1" has a running turn on "codex"
      When the MC dies
      And the MC restarts and a client connects
      Then the run of "t1" is still running

    Scenario: A turn survives a second restart
      Given thread "t1" has a running turn on "claudeAgent"
      When the MC dies
      And the MC restarts
      And the MC dies
      And the MC restarts
      Then the provider process of "t1" is the one that was running
      And the run of "t1" is still running

    # One program too: a thread with two on one conversation is hal-c2/hal-c2#254.
    Scenario Outline: The next message goes to the program that was idle
      Given thread "t1" finished a turn on "<provider>" and its provider process is live
      When the MC dies
      And the MC restarts
      And the user sends "Back" to "t1" after the restart
      Then a new run of "t1" completed on that program

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    Scenario Outline: A question asked before the restart can still be answered
      Given thread "t1" has a turn on "<provider>" waiting on an approval
      When the MC dies
      And the MC restarts
      Then the approval of "t1" is still pending
      And the user approves it, and the run of "t1" completes on that program

      Examples:
        | provider    |
        | codex       |
        | cursor      |
        | grok        |
        | opencode    |
        | acpRegistry |

      # Their fakes ask only when a scenario scripts it; the runtime path is the same.
      @backlog
      Examples:
        | provider    |
        | claudeAgent |
        | antigravity |
        | pi          |
        | muse        |

    Scenario Outline: A reattached program that crashes ends its turn as failed
      Given thread "t1" has a running turn on "<provider>"
      When the MC dies
      And the MC restarts
      And the provider process of "t1" crashes after the restart
      Then the run of "t1" fails

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    Scenario: A machine that rebooted has nothing to reattach
      Given thread "t1" has a running turn on "codex"
      When the MC dies
      And the machine reboots
      And the MC restarts
      Then the run of "t1" is interrupted

  Rule: What a restart must not repeat or forget

    Scenario: Text streamed before a pause is not written again after a restart
      Given thread "t1" has a turn on "codex" that streamed a paragraph and paused
      When the MC dies
      And the MC restarts
      Then "t1" shows that paragraph once

    Scenario: Text a quiet program streamed stays once across two restarts
      Given thread "t1" has a turn on "codex" that streamed a paragraph and paused
      When the MC dies
      And the MC restarts
      And the MC dies
      And the MC restarts
      Then "t1" shows that paragraph once

    # The MC went between a turn's end and moving the queue on.
    Scenario: A queued run with nothing ahead of it is held, not left waiting
      Given thread "t1" finished a turn on "codex" and its provider process is live
      And a queued run waits in "t1"
      When the MC dies
      And the MC restarts
      Then that provider process has been killed
      And the queued run of "t1" is held

    # The stop went out before the MC left, and the program never answers it.
    Scenario Outline: A stop that was out when the MC went still settles
      Given thread "t1" has a running turn on "<provider>"
      And a stop of "t1" is out and "<provider>" will not answer it
      When the MC dies
      And the MC restarts
      Then the run of "t1" ends as <ending>

      Examples:
        | provider    | ending      |
        | codex       | interrupted |
        | claudeAgent | interrupted |
        | antigravity | failed      |

    Scenario: A second Antigravity thread leaves an adopted program's files alone
      Given thread "t1" has a running turn on "antigravity"
      When the MC dies
      And the MC restarts
      And a second Antigravity thread starts
      Then the runtime directory of "t1" is still there

    Scenario: A sign-out reaches an adopted Antigravity program
      Given thread "t1" has a running turn on "antigravity"
      When the MC dies
      And the MC restarts
      And the user signs out of Antigravity
      Then the provider process of "t1" has stopped

  Rule: Still to come

    @backlog
    Scenario Outline: What a provider wrote while the MC was down reaches the thread once, in order
      Given thread "t1" has a running turn on "<provider>"
      When the MC dies partway through reading a line from the provider
      And the provider writes three more updates
      And the MC restarts
      Then "t1" shows every update once, in the order the provider wrote them

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    @backlog
    Scenario Outline: A HAL-C2 tool call the restart cut off does not end the turn
      Given thread "t1" has a turn on "<provider>" calling a HAL-C2 tool
      When the MC dies before answering the call
      And the MC restarts
      Then the provider hears that the call failed or receives its answer
      And the run of "t1" is still running

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    @backlog
    Scenario Outline: Background work goes on through a restart
      Given thread "t1" left a command running in the background on "<provider>"
      When the MC dies
      And the MC restarts
      Then the command is still running
      And "t1" lists the command as background work
      And no continuation message is sent to "t1"

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | antigravity |

    @backlog
    Scenario: A Claude background subagent goes on through a restart
      Given thread "t1" left a Claude subagent running in the background
      When the MC dies
      And the MC restarts
      Then "t1" lists the subagent as background work
      When Claude reports the subagent completed with "3 files"
      Then the subagent of "t1" is completed with "3 files"

    @backlog
    Scenario Outline: A reattached idle session is still released
      Given thread "t1" finished a turn on "<provider>" and its provider process is live
      When the MC dies
      And the MC restarts
      And "t1" has had no activity for 30 minutes
      And the MC checks for idle sessions
      Then the provider process of "t1" stops
      And no program of "t1" is left running

      Examples:
        | provider    |
        | codex       |
        | claudeAgent |
        | cursor      |
        | grok        |
        | opencode    |
        | antigravity |
        | pi          |
        | muse        |
        | acpRegistry |

    @backlog
    Scenario Outline: A program that cannot be reattached is killed before anything resumes
      Given thread "t1" has a running turn on "claudeAgent"
      And project "demo" continues threads after a server update
      When the MC dies
      And <reason>
      And the MC restarts
      Then that provider process has been killed
      And the run of "t1" is interrupted
      And "t1" receives "Continue where you left off." from the server on the same model

      Examples:
        | reason                                      |
        | the program's pipes are gone                |
        | the program does not answer on reattaching  |
        | the new MC cannot read the program's format |

    @backlog
    Scenario: A pid reused by another program is left alone
      Given thread "t1" has a running turn on "codex"
      When the MC dies
      And the program ends and another program takes its pid
      And the MC restarts
      Then the other program is still running
      And the run of "t1" is interrupted

    # Windows has no named pipe that outlives its owner this way, and tracks no programs.
    @backlog
    Scenario: On Windows a restart still interrupts the turn
      Given the MC runs on Windows
      And thread "t1" has a running turn on "codex"
      When the MC restarts
      Then the run of "t1" is interrupted

    @backlog
    Scenario: Stopping the MC for good stops its programs
      Given thread "t1" has a running turn on "codex"
      When the user stops the MC without restarting it
      Then no program of "t1" is left running

    # A service manager that kills a unit's processes when it stops (systemd's
    # KillMode=mixed) would end them before the next MC starts, so the units say otherwise.
    @backlog
    Scenario: A restart by the service manager keeps the programs
      Given the MC runs as a service
      And thread "t1" has a running turn on "codex"
      When the service restarts
      Then the provider process of "t1" is the one that was running

    # The shim gives an MC ten minutes (HalC2.Subprocess.Durable). What runs here is the
    # program going on in the meantime; waiting that out is not a test worth its time.
    @backlog
    Scenario: A program whose MC never came back ends itself
      Given thread "t1" has a running turn on "codex"
      When the MC dies and does not start again within ten minutes
      Then no program of "t1" is left running
