# Sources:
#   apps/server-ex/lib/hal_c2/diagnostics.ex (process list, history, signals, traces)
#   apps/server-ex/lib/hal_c2/traces.ex (MC spans, client trace forwarding, trace diagnostics)
#   apps/server-ex/test/mc_parity_test.exs (diagnostics RPCs aligned)
#   apps/server-ex/test/features_backlog_test.exs (client trace forwarding)
#   packages/contracts/src/rpc.ts (server.getProcessDiagnostics, server.getProcessResourceHistory, server.signalProcess, server.getTraceDiagnostics)
#   apps/web/src/components/settings/DiagnosticsSettings.tsx
#   apps/web/src/components/settings/ProcessSignalActions.tsx
#   apps/web/src/components/settings/ExpandableText.tsx (long causes and messages)
#   apps/tui/src/features.backlog.test.ts (provider maintenance and server diagnostics)
#   apps/tui/src/host/sections/diagnostics.ts (bounded lists, the force kill that asks first)

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

  # Likely already implemented: apps/server-ex/lib/hal_c2/traces.ex (diagnostics/0)
  @backlog @mc
  Scenario: Trace diagnostics list the latest warnings and errors
    Given the MC recorded warning and error logs inside its spans
    When the user asks for trace diagnostics
    Then the latest warnings and errors are listed with the span they happened in

  # Likely already implemented: apps/server-ex/lib/hal_c2/traces.ex (diagnostics/0)
  @backlog @mc
  Scenario: Trace diagnostics count spans that take a second or more
    Given the MC recorded spans that took under a second and spans that took a second or more
    When the user asks for trace diagnostics
    Then the slow span count includes only the spans that took a second or more

  # Likely already implemented: apps/server-ex/lib/hal_c2/traces.ex (diagnostics/0)
  @backlog @mc
  Scenario: Trace diagnostics skip lines they cannot read and say how many
    Given the trace file has lines that are not trace records
    When the user asks for trace diagnostics
    Then the unreadable lines are left out and their count is reported

  # Likely already implemented: apps/server-ex/lib/hal_c2/traces.ex (diagnostics/0)
  @backlog @mc
  Scenario: Trace diagnostics with no trace file yet say so
    Given tracing is on but the MC has not written a trace file
    When the user asks for trace diagnostics
    Then the user is told "No local trace files were found."

  @mc
  Scenario: Clients forward their traces to the MC
    When a client sends its traces to the MC
    # With tracing on, the file holds what clients send beside the MC's own spans.
    Then the MC records them in its trace file

  @shared @backlog-mobile
  Scenario: Force killing a process asks first
    When the user force kills a process
    Then the user is asked to confirm because the process cannot handle it
    And cancelling leaves the process running

  @desktop
  Scenario: The user opens the logs folder
    When the user opens the logs folder
    Then it opens in the user's preferred editor
    But if no editor is available the user is told "No available editors found."

  @tui
  Scenario: Diagnostics in the terminal client show bounded summaries
    When the user opens diagnostics in the terminal client
    Then long process lists and failures are summarised

  @backlog @desktop
  Scenario: Live processes total what the MC's children use
    Given the MC has started a provider and a terminal
    When the user opens diagnostics
    Then the live processes show how many child processes there are
    And their total CPU and total memory
    And the MC's own process id
    And the totals leave out the desktop app and other parent processes

  @backlog @desktop
  Scenario Outline: The diagnostics process list labels a process by what it is
    Given the MC has started <process>
    When the user opens diagnostics
    Then the process is labelled "<label>"

    Examples:
      | process                                      | label      |
      | a Codex, Claude, OpenCode or Cursor CLI      | Agent      |
      | a shell started by the MC                    | Process    |
      | a process started by one of those            | Subprocess |

  @backlog @desktop
  Scenario: The user collapses a process to hide what it started
    Given a provider process has started subprocesses
    When the user collapses the provider process
    Then its subprocesses and theirs are hidden
    And expanding it shows them again

  @backlog @desktop
  Scenario: The live processes say when nothing is running
    Given the MC has no live descendant processes
    When the user opens diagnostics
    Then the live processes say "No live descendant processes found."

  @backlog @desktop
  Scenario: A process is stopped one signal at a time
    Given the user has sent SIGINT to a process and it has not answered yet
    Then sending another signal to that same process is not possible
    And other processes can still be signalled

  @backlog @desktop
  Scenario: Signalling a process that already exited refreshes the list
    Given the process list still shows a process that has exited
    When the user sends it SIGINT
    Then the user is told "Process already exited"
    And the process list is refreshed

  @backlog @desktop
  Scenario: A signal that could not be sent is reported
    Given the MC cannot send SIGINT to a process
    When the user sends it SIGINT
    Then the user is told "Could not send SIGINT" with the MC's reason
    And the process list is refreshed

  @backlog @desktop
  Scenario: Confirming a force kill can itself fail
    Given the confirmation for a force kill cannot be shown
    When the user force kills a process
    Then the user is told "Could not confirm signal"
    And nothing is sent to the process

  @backlog @desktop
  Scenario: Resource history opens on the last fifteen minutes
    When the user opens diagnostics
    Then the resource history covers the last 15 minutes
    And the user can choose 5 minutes, 15 minutes, 30 minutes or 1 hour

  @backlog @desktop
  Scenario: Resource history totals and per-process figures
    Given the MC has an hour of samples
    When the user views the last 15 minutes
    Then the history shows approximate CPU time, how many samples are kept, the sampling interval and how many processes it covers
    And each process shows its CPU time, current, average and peak CPU, highest memory, command and id
    And the MC's own process is marked apart from its children

  @backlog @desktop
  Scenario Outline: Resource history says why it has nothing to show
    Given <state>
    When the user views resource history
    Then the history says "<message>"

    Examples:
      | state                                        | message                                           |
      | the first samples are still being collected | Collecting process resource samples...            |
      | no samples fall inside the chosen period    | No process resource samples found for this window. |

  @backlog @desktop
  Scenario: Each diagnostics list says when it was last checked
    When the user opens diagnostics
    Then live processes, resource history and trace diagnostics each say how long ago they were checked
    And each says "Checking" until its first answer arrives
    And each can be refreshed on its own

  @backlog @desktop
  Scenario: Trace diagnostics count spans, failures, slow spans and unreadable lines
    Given the MC recorded traces
    When the user opens diagnostics
    Then trace diagnostics show the number of spans and of failures
    And the number of slow spans, with the duration that makes a span slow
    And the number of trace lines that could not be parsed

  @backlog @desktop
  Scenario: Trace diagnostics warn when some trace files could not be read
    Given some of the MC's trace files cannot be read
    When the user opens diagnostics
    Then the user is told "Some trace files could not be read, so diagnostics may be incomplete." with the reason
    And the traces that could be read are still shown

  @backlog @desktop
  Scenario: Trace diagnostics that cannot be loaded say why
    Given the MC cannot read trace diagnostics at all
    When the user opens diagnostics
    Then trace diagnostics show the error instead of numbers

  @backlog @desktop
  Scenario: Failures show their cause, duration and when they ended
    Given the MC recorded failing spans
    When the user opens diagnostics
    Then the latest failures list each span's name, cause, duration and when it ended
    And a long cause is shortened until the user expands it, and can be shortened again

  @backlog @desktop
  Scenario: Repeated failures are grouped by span and cause
    Given the same span failed with the same cause several times
    When the user opens diagnostics
    Then the most common failures show it once with how many times it failed and when it was last seen

  @backlog @desktop
  Scenario: A slow span's trace id can be copied
    Given the MC recorded slow spans
    When the user copies the trace id of the slowest span
    Then the full trace id is on the clipboard
    And the shortened id is shown in the list

  @backlog @desktop
  Scenario: Warnings and errors logged inside spans are listed
    Given spans logged warnings and errors
    When the user opens diagnostics
    Then each warning and error shows its time, level, span, message and trace id
    And a long message is shortened until the user expands it

  @backlog @desktop
  Scenario: The busiest span names are listed with their timings
    Given the MC recorded spans
    When the user opens diagnostics
    Then the busiest span names show how often they ran, how often they failed, and their average and longest duration

  @backlog @desktop
  Scenario Outline: A trace list with nothing in it says so
    Given the MC has recorded no <items>
    When the user opens diagnostics
    Then that list says "<message>"

    Examples:
      | items                  | message                   |
      | failed spans           | No failed spans found.    |
      | repeated failures      | No repeated failures found. |
      | spans                  | No spans found.           |
      | warnings or errors     | No warnings or errors found. |

  @backlog @desktop
  Scenario: The logs folder cannot be opened when the MC keeps none
    Given the MC reports no logs directory
    When the user looks for the logs folder
    Then opening it is not possible

  @backlog @desktop
  Scenario: Opening the logs folder can fail
    Given the user's editor cannot open the logs folder
    When the user opens the logs folder
    Then the user is told why, or "Unable to open logs folder."

  # Legacy: apps/web/src/components/settings/DiagnosticsSettings.tsx (isInitialLoading, formatRelative)
  @backlog @desktop
  Scenario Outline: A list says it is loading until its first answer, not that it is empty
    Given the MC has not answered for the <list> yet
    When the user opens diagnostics
    Then that list says "<message>"

    Examples:
      | list                | message                         |
      | live processes      | Loading live processes...       |
      | failed spans        | Loading failures...             |
      | repeated failures   | Loading failure groups...       |
      | slowest spans       | Loading slow spans...           |
      | warnings and errors | Loading recent logs...          |
      | busiest span names  | Loading span names...           |

  # Legacy: apps/web/src/components/settings/DiagnosticsSettings.tsx (formatRelative)
  @backlog @desktop
  Scenario: A failure or span with no recorded time says so where its age would be
    Given the MC recorded a failed span that has no end time
    When the user opens diagnostics
    Then that failure says "No trace records" where it would say how long ago it ended
