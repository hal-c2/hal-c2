# Sources:
#   apps/server-ex/lib/hal_c2/diagnostics.ex (process list, history, signals, traces)
#   apps/server-ex/lib/hal_c2/traces.ex (MC spans, client trace forwarding, trace diagnostics)
#   apps/server-ex/test/mc_parity_test.exs (diagnostics RPCs aligned)
#   apps/server-ex/test/features_backlog_test.exs (client trace forwarding)
#   packages/contracts/src/rpc.ts (server.getProcessDiagnostics, server.getProcessResourceHistory, server.signalProcess, server.getTraceDiagnostics)
#   apps/web/src/components/settings/DiagnosticsSettings.tsx
#   apps/tui/src/features.backlog.test.ts (provider maintenance and server diagnostics)

Feature: Diagnostics
  Diagnostics lets the user see what the MC has started, how much it uses,
  stop runaway processes, and read recent failures.

  Background:
    Given an MC running a provider session and a terminal

  @mc
  Scenario: The user lists the processes the MC started
    When the user opens diagnostics
    Then each process shows its id, CPU, memory and command

  @mc
  Scenario Outline: The user reads recent resource history
    When the user views the last <window> of resource history
    Then the history shows average and peak CPU for that window

    Examples:
      | window     |
      | 5 minutes  |
      | 1 hour     |

  @mc
  Scenario: Resource history starts over when the MC restarts
    Given the MC collected an hour of history
    When the MC restarts
    Then the history is empty

  @mc
  Scenario Outline: The user signals a process
    When the user sends <signal> to the provider process
    Then the process receives <signal>

    Examples:
      | signal  |
      | SIGINT  |
      | SIGKILL |

  @mc
  Scenario Outline: A signal the MC will not send
    When the user signals <target>
    Then the user is told "<message>"

    Examples:
      | target                              | message                                     |
      | a process the MC did not start    | That process is not one this MC started. |
      | the MC itself                     | The MC itself cannot be signalled from here. |
      | a process that exited and whose id was reused | That process has already exited. |

  @mc
  Scenario: The MC says it does not record traces
    When the user asks for trace diagnostics
    Then the user is told "This MC does not record traces."

  @mc
  Scenario: Trace diagnostics list the latest and slowest failures
    Given the MC recorded failing and slow spans
    When the user asks for trace diagnostics
    Then the latest failures, most common failures and slowest spans are listed

  @mc
  Scenario: Clients forward their traces to the MC
    When a client sends its traces to the MC
    # With tracing on, the file holds what clients send beside the MC's own spans.
    Then the MC records them in its trace file

  @shared @backlog-mobile @backlog-tui
  Scenario: Force killing a process asks first
    When the user force kills a process
    Then the user is asked to confirm because the process cannot handle it
    And cancelling leaves the process running

  @desktop
  Scenario: The user opens the logs folder
    When the user opens the logs folder
    Then it opens in the user's preferred editor
    But if no editor is available the user is told "No available editors found."

  @backlog @tui
  Scenario: Diagnostics in the terminal client show bounded summaries
    When the user opens diagnostics in the terminal client
    Then long process lists and failures are summarised
