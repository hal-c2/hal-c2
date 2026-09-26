# Sources:
#   docs/internals/resource-telemetry.md
#   apps/server-ex/lib/hal_c2/diagnostics.ex (ps sampling, one hour of samples, retry)
#   apps/server-ex/lib/hal_c2/web/socket.ex (resourceTelemetry subscription)
#   packages/contracts/src/resourceTelemetry.ts
#   packages/contracts/src/rpc.ts (subscribeResourceTelemetry, server.getResourceTelemetryHistory, server.retryResourceTelemetry)
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.tsx
#   apps/web/src/components/settings/ResourceTelemetryDiagnostics.logic.ts

Feature: Resource monitor
  The resource monitor shows live CPU and memory for everything the node runs,
  grouped by what it is for, and keeps a bounded history.

  @node
  Scenario: Watching the monitor streams live snapshots
    When the user watches the resource monitor
    Then a fresh snapshot of the process tree arrives every few seconds

  @node
  Scenario: The node samples less often while nobody watches
    Given no client watches the resource monitor
    Then the node samples every 15 seconds
    And it keeps at most one hour of samples

  @node
  Scenario: Retrying the monitor takes a sample now
    When the user retries the resource monitor
    Then a new snapshot is taken immediately

  @node
  Scenario: Host power and I/O are reported as unavailable on the node
    When the user watches the resource monitor
    Then host power state and application I/O are shown as unavailable

  @backlog @desktop
  Scenario: The desktop app reports host power to the monitor
    Given the node runs inside the desktop app on a laptop on battery
    When the user watches the resource monitor
    Then the monitor shows the host is on battery

  @backlog @shared
  Scenario: Processes are grouped by what they are for
    When the user watches the resource monitor
    Then processes are grouped as server, provider and terminal
    And each group can be collapsed and expanded again

  @backlog @node
  Scenario: Application I/O is broken down by operation
    When the user watches the resource monitor
    Then logical bytes read and written are shown per operation
