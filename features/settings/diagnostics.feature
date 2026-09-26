# Sources:
#   apps/server-ex/lib/hal_c2/diagnostics.ex (process list, history, signals, traces)
#   apps/server-ex/lib/hal_c2/traces.ex (node spans, client trace forwarding, trace diagnostics)
#   apps/server-ex/test/node_parity_test.exs (diagnostics RPCs aligned)
#   apps/server-ex/test/features_backlog_test.exs (client trace forwarding)
#   packages/contracts/src/rpc.ts (server.getProcessDiagnostics, server.getProcessResourceHistory, server.signalProcess, server.getTraceDiagnostics)
#   apps/web/src/components/settings/DiagnosticsSettings.tsx
#   apps/tui/src/features.backlog.test.ts (provider maintenance and server diagnostics)

Feature: Diagnostics
  Diagnostics lets the user see what the node has started, how much it uses,
  stop runaway processes, and read recent failures.

  Background:
    Given a node running a provider session and a terminal

  @node
  Scenario: The user lists the processes the node started
    When the user opens diagnostics
    Then each process shows its id, CPU, memory and command

  @node
  Scenario Outline: The user reads recent resource history
    When the user views the last <window> of resource history
    Then the history shows average and peak CPU for that window

    Examples:
      | window     |
      | 5 minutes  |
      | 1 hour     |

  @node
  Scenario: Resource history starts over when the node restarts
    Given the node collected an hour of history
    When the node restarts
    Then the history is empty

  @node
  Scenario Outline: The user signals a process
    When the user sends <signal> to the provider process
    Then the process receives <signal>

    Examples:
      | signal  |
      | SIGINT  |
      | SIGKILL |

  @node
  Scenario Outline: A signal the node will not send
    When the user signals <target>
    Then the user is told "<message>"

    Examples:
      | target                              | message                                     |
      | a process the node did not start    | That process is not one this node started. |
      | the node itself                     | The node itself cannot be signalled from here. |
      | a process that exited and whose id was reused | That process has already exited. |

  @node
  Scenario: The node says it does not record traces
    When the user asks for trace diagnostics
    Then the user is told "This node does not record traces."

  @node
  Scenario: Trace diagnostics list the latest and slowest failures
    Given the node recorded failing and slow spans
    When the user asks for trace diagnostics
    Then the latest failures, most common failures and slowest spans are listed

  @node
  Scenario: Clients forward their traces to the node
    When a client sends its traces to the node
    # With tracing on, the file holds what clients send beside the node's own spans.
    Then the node records them in its trace file

  @backlog @shared
  Scenario: Force killing a process asks first
    When the user force kills a process
    Then the user is asked to confirm because the process cannot handle it
    And cancelling leaves the process running

  @backlog @desktop
  Scenario: The user opens the logs folder
    When the user opens the logs folder
    Then it opens in the user's preferred editor
    But if no editor is available the user is told "No available editors found."

  @backlog @tui
  Scenario: Diagnostics in the terminal client show bounded summaries
    When the user opens diagnostics in the terminal client
    Then long process lists and failures are summarised
