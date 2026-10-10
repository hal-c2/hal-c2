# Sources:
#   docs/internals/resource-telemetry.md
#   apps/server/src/resourceTelemetry/NativeTelemetryClient.ts (sample intervals by power state, stale host power,
#     restart backoff, give-up rule, request timeouts)
#   apps/server/src/resourceTelemetry/ResourceMonitorBinary.ts, ResourceTelemetry.ts (monitor binary errors, stale generations)
#   apps/server/src/resourceTelemetry/DesktopTelemetryReceiver.ts (host power feed staleness)
#   apps/desktop/src/telemetry/DesktopTelemetryPublisher.ts (the desktop's host power and process reporting)
#   apps/server-ex/lib/hal_c2/diagnostics.ex (ps sampling, one hour of samples, retry)
#   apps/server-ex/lib/hal_c2/diagnostics/attribution.ex (application I/O by operation)
#   apps/server/src/resourceTelemetry/ResourceAttribution.ts, apps/server/src/observability/Layers/Observability.ts, apps/server/src/provider/Layers/EventNdjsonLogger.ts (what records application I/O)
#   apps/server-ex/lib/hal_c2/web/socket.ex (resourceTelemetry subscription)
#   packages/contracts/src/resourceTelemetry.ts
#   packages/contracts/src/rpc.ts (subscribeResourceTelemetry, server.getResourceTelemetryHistory, server.retryResourceTelemetry)
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.tsx
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.logic.ts
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.logic.test.ts (collapse by parentage, retry rule, bar scaling)
#   apps/web/src/components/settings/ProcessSignalActions.tsx
#   apps/tui/src/host/sections/resourceMonitor.ts (groups by purpose)

Feature: Resource monitor
  The resource monitor shows live CPU and memory for everything the MC runs,
  grouped by what it is for, and keeps a bounded history.

  @mc
  Scenario: Watching the monitor streams live snapshots
    When the user watches the resource monitor
    Then a fresh snapshot of the process tree arrives every few seconds

  @mc
  Scenario: The MC samples less often while nobody watches
    Given no client watches the resource monitor
    Then the MC samples every 15 seconds
    And it keeps at most one hour of samples

  @mc
  Scenario: Retrying the monitor takes a sample now
    When the user retries the resource monitor
    Then a new snapshot is taken immediately

  @mc
  Scenario: Host power is reported as unavailable on the MC
    When the user watches the resource monitor
    Then host power state is shown as unavailable

  # Likely already implemented: apps/server-ex/lib/hal_c2/diagnostics.ex (stale host power)
  @backlog @mc
  Scenario: Host power that stops being reported is shown as stale
    Given a client reported the host's power state to the MC
    When no newer report arrives for longer than the reporting interval plus a grace period
    Then the monitor shows the host power as stale rather than current

  @backlog @mc
  Scenario: The monitor samples less often on battery and when the host is constrained
    Given the host is on battery or in low power mode or thermally throttled
    When the user watches the resource monitor
    Then samples arrive every five seconds on battery
    And every fifteen seconds when the host is in low power mode, locked, suspended or thermally throttled

  # The legacy server supervised a native monitor sidecar; the MC samples with `ps` and has no sidecar,
  # so these may not carry over in this shape. Kept so the ledger records what the legacy server did.
  # Legacy: apps/server/src/resourceTelemetry/NativeTelemetryClient.ts (restartDelay), NativeTelemetryClient.test.ts
  @backlog @mc
  Scenario: A monitor that stops is started again after a growing delay
    Given the resource monitor stops unexpectedly
    When it keeps failing to start
    Then it is started again after half a second, then a second, then twice as long each time up to ten seconds
    And the monitor is shown as degraded in between

  # Legacy: apps/server/src/resourceTelemetry/NativeTelemetryClient.ts (retainRecentNativeTelemetryFailures, FAILURE_WINDOW_MS)
  @backlog @mc
  Scenario: A failure long after the last one starts from the shortest delay
    Given the resource monitor failed twice a minute and a half ago
    When it fails again
    Then it is started again after half a second

  # Legacy: apps/server/src/resourceTelemetry/NativeTelemetryClient.ts (MAX_FAILURES_PER_WINDOW)
  @backlog @mc
  Scenario: A monitor that fails five times in a minute is left unavailable until retried
    Given the resource monitor failed four times in the last minute
    When it fails again
    Then it is shown as unavailable with its last error
    And it is not started again until the user retries it
    When the user retries it
    Then it starts at once with no failures held against it

  # Legacy: apps/server/src/resourceTelemetry/NativeTelemetryClient.ts (retry while waiting)
  @backlog @mc
  Scenario: A retry during a restart delay starts the monitor at once
    Given the resource monitor is waiting to be started again
    When the user retries it
    Then it starts without waiting out the delay

  # Legacy: apps/server/src/resourceTelemetry/NativeTelemetryClient.ts (HANDSHAKE_TIMEOUT, *_REQUEST_TIMEOUT)
  @backlog @mc
  Scenario Outline: A monitor that does not answer in time is treated as failed
    Given the resource monitor is running
    When it does not answer <request> within <limit>
    Then the request fails and the monitor is restarted

    Examples:
      | request                   | limit      |
      | its start-up handshake    | 5 seconds  |
      | a sample                  | 5 seconds  |
      | a process table           | 5 seconds  |
      | a history request         | 15 seconds |

  # Legacy: apps/server/src/resourceTelemetry/ResourceTelemetry.test.ts ("rejects buffered snapshots from an earlier sidecar generation")
  @backlog @mc
  Scenario: A snapshot from a monitor that has since been replaced is discarded
    Given the resource monitor was restarted
    When a snapshot from the earlier monitor arrives late
    Then it is not shown

  # Legacy: apps/server/src/resourceTelemetry/ResourceMonitorBinary.ts (HAL_C2_RESOURCE_MONITOR_PATH, platform and libc checks)
  @backlog @mc
  Scenario Outline: A monitor that cannot be started says why
    Given <situation>
    When the MC starts the resource monitor
    Then the monitor is unavailable with the message "<message>"

    Examples:
      | situation                                                         | message                                                              |
      | the platform and architecture have no monitor build               | Resource monitoring is unsupported on <platform>/<architecture>.    |
      | no monitor build or override is found for this platform           | Resource monitor binary was not found for <platform>/<architecture>. |
      | the configured monitor path is not an executable file             | Resource monitor binary at '<path>' is not executable.             |

  @backlog @desktop
  Scenario: The desktop app reports host power to the monitor
    Given the MC runs inside the desktop app on a laptop on battery
    When the user watches the resource monitor
    Then the monitor shows the host is on battery

  # Legacy: apps/desktop/src/telemetry/DesktopTelemetryPublisher.ts (sampleInterval, diagnostics demand)
  @backlog @desktop
  Scenario: The desktop app reports host power rarely while nobody watches the monitor
    Given no client watches the resource monitor
    When the user is at the computer
    Then the desktop app reports host power every 30 seconds
    When the user is idle, the session is locked or the computer is suspended
    Then it reports every 2 minutes
    And the MC can change both intervals

  @backlog @desktop
  Scenario: The desktop app's own processes are measured only while someone watches
    Given no client watches the resource monitor
    Then the desktop app reports no process usage
    When a client starts watching the resource monitor
    Then the desktop app starts reporting its processes
    And it stops again when the last watcher goes away

  @shared @backlog-mobile
  Scenario: Processes are grouped by what they are for
    When the user watches the resource monitor
    Then processes are grouped as server, provider and terminal
    And each group can be collapsed and expanded again

  @mc
  Scenario: Application I/O is broken down by operation
    Given the MC has written trace records and provider event logs
    When the user watches the resource monitor
    Then logical bytes read and written are shown per operation

  @backlog @desktop
  Scenario: The monitor totals everything HAL-C2 runs
    When the user watches the resource monitor
    Then it shows current CPU with the CPU time observed so far
    And resident memory with the combined process peaks
    And how many processes there are, with how many have started and exited
    And read and write throughput with the bytes observed

  @backlog @desktop
  Scenario: The monitor says how often it samples and when it last did
    When the user watches the resource monitor
    Then it says how often it samples, such as "Sampling every 2 seconds"
    And how long ago it last updated
    And before the first sample it says "Waiting for sample"

  @backlog @desktop
  Scenario Outline: Heavy writing is flagged
    Given HAL-C2 is writing <rate> to disk
    When the user watches the resource monitor
    Then the write throughput is shown as <flag>

    Examples:
      | rate                | flag      |
      | under 1 MB a second | normal    |
      | 1 MB a second       | a warning |
      | 10 MB a second      | an alarm  |

  @backlog @desktop
  Scenario Outline: The monitor reports a throttled CPU
    Given the host reports <limit> and a thermal state of "<thermal>"
    When the user watches the resource monitor
    Then the CPU speed limit shows <shown> beside the thermal state
    And <flag>

    Examples:
      | limit             | thermal | shown   | flag                          |
      | no speed limit    | nominal | Unknown | it is not flagged             |
      | a limit of 100%   | nominal | 100%    | it is not flagged             |
      | a limit of 60%    | serious | 60%     | it is flagged as throttled    |

  @backlog @desktop
  Scenario: The monitor splits usage between the backend, the desktop and itself
    When the user watches the resource monitor
    Then usage is shown for the MC and its agents, for the desktop app and for the monitor's own overhead
    And each shows its process count, CPU, memory, and read and write rates

  @backlog @desktop
  Scenario: Host state shows power, idle, session and thermal state
    Given the desktop app supplies host signals
    When the user watches the resource monitor
    Then the host state shows whether it is on battery or external power
    And whether low power mode is on
    And whether the user is idle, with how many seconds
    And whether the session is locked or suspended
    And the thermal state, highlighted when it is serious or critical

  @backlog @desktop
  Scenario: Collection health names each source and its last error
    When the user watches the resource monitor
    Then the native process monitor and the desktop app each show their status
    And the last error each reported, or "No reported errors"
    And how long a collection took
    And how many processes were retained out of those scanned
    And how many were inaccessible
    And the monitor sidecar's version and process id, or "Unavailable"
    And how many times the monitor restarted

  @backlog @desktop
  Scenario Outline: Retrying the monitor is offered only when it needs it
    Given the process monitor is <state>
    When the user watches the resource monitor
    Then retrying the monitor is <offered>

    Examples:
      | state                                        | offered     |
      | healthy                                      | not offered |
      | still starting                               | not offered |
      | degraded                                     | offered     |
      | unavailable                                  | offered     |
      | stopped                                      | offered     |
      | failing to deliver its first snapshot        | offered     |

  @backlog @desktop
  Scenario: A retry that fails is reported
    Given the process monitor is stopped
    When the user retries the monitor and the retry fails
    Then the user is told "Could not restart resource monitor" with the reason

  @backlog @desktop
  Scenario: The resource timeline charts CPU and I/O for the chosen period
    When the user watches the resource timeline
    Then it covers the last 15 minutes until the user chooses 5 minutes, 30 minutes or 1 hour
    And each interval shows its average CPU, peak CPU, bytes read and bytes written
    And an interval with no activity shows no bar while a small one stays visible
    And CPU bars are scaled to the averages, not to brief peaks

  @backlog @desktop
  Scenario: The timeline lists each process the history retained
    Given the MC retained samples for several processes
    When the user watches the resource timeline
    Then each process shows its category, CPU time, peak CPU, peak memory, bytes read and written, sample count and id
    And with no retained samples it says "No retained process samples in this window."

  @backlog @desktop
  Scenario Outline: The resource monitor names a live process by what it is for
    Given the MC runs <process>
    When the user watches the resource monitor
    Then the process is listed as "<category>"

    Examples:
      | process                           | category       |
      | the MC itself                     | Server         |
      | a helper the MC started           | Backend child  |
      | an agent CLI                      | Provider       |
      | a terminal's shell                | Terminal       |
      | the resource monitor's sidecar    | Monitor        |
      | another HAL-C2 process            | HAL-C2 process |

  @backlog @desktop
  Scenario: The user collapses a process in the live process tree
    Given a provider process has started subprocesses that have started others
    When the user collapses the provider process
    Then all its descendants are hidden, even when the list is not in tree order
    And expanding it shows them again

  @backlog @desktop
  Scenario: Only processes the MC started can be stopped from the process tree
    When the user watches the live process tree
    Then the MC's helpers, providers and terminals offer to stop them
    And the MC itself and other HAL-C2 processes show no controls

  @backlog @desktop
  Scenario: The process tree says it is waiting for the monitor
    Given the process monitor has not delivered a snapshot
    When the user watches the live process tree
    Then it says "Waiting for the native process monitor."

  @backlog @desktop
  Scenario Outline: A process's I/O says how it was counted
    Given a process's I/O was counted as <semantics>
    When the user looks at the bytes it wrote
    Then the figure is labelled "<label>"

    Examples:
      | semantics | label         |
      | storage   | Storage bytes |
      | logical   | Logical bytes |
      | all I/O   | All I/O bytes |
      | nothing   | Unavailable   |

  @backlog @desktop
  Scenario: Application I/O with nothing recorded says so
    Given the MC has recorded no instrumented application I/O
    When the user watches the resource monitor
    Then application I/O says "No instrumented application I/O has been recorded yet."
    And once recorded each operation shows its component, bytes read and written, how many times it ran and how long it took

  # Only meaningful when the settings page ran in a browser tab: there is no web client.
  @dropped @desktop
  Scenario: A browser tab says desktop-only sources are available in the desktop app
    Given the settings page runs in a browser
    When the user watches the resource monitor
    Then the desktop source says "Available when this page runs inside the desktop app."
