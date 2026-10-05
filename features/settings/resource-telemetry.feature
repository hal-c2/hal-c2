# Sources:
#   docs/internals/resource-telemetry.md
#   apps/server-ex/lib/hal_c2/diagnostics.ex (ps sampling, one hour of samples, retry)
#   apps/server-ex/lib/hal_c2/diagnostics/attribution.ex (application I/O by operation)
#   apps/server/src/resourceTelemetry/ResourceAttribution.ts, apps/server/src/observability/Layers/Observability.ts, apps/server/src/provider/Layers/EventNdjsonLogger.ts (what records application I/O)
#   apps/server-ex/lib/hal_c2/web/socket.ex (resourceTelemetry subscription)
#   packages/contracts/src/resourceTelemetry.ts
#   packages/contracts/src/rpc.ts (subscribeResourceTelemetry, server.getResourceTelemetryHistory, server.retryResourceTelemetry)
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.tsx
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.logic.ts
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

  @backlog @desktop
  Scenario: The desktop app reports host power to the monitor
    Given the MC runs inside the desktop app on a laptop on battery
    When the user watches the resource monitor
    Then the monitor shows the host is on battery

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
