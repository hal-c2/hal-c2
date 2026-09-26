# Sources:
#   apps/server-ex/lib/hal_c2/diagnostics.ex (ps sampler, process list, telemetry, signalProcess, traces)
#   apps/server-ex/lib/hal_c2/environment.ex (server config observability, logs directory)
#   apps/server-ex/lib/hal_c2/web/socket.ex (resourceTelemetry shape)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (client-trace-forwarding)
#   packages/contracts/src/server.ts (server.getTraceDiagnostics, server.getProcessDiagnostics,
#     server.getHostResources, server.getProcessResourceHistory, server.getResourceTelemetryHistory,
#     server.retryResourceTelemetry, server.signalProcess, subscribeResourceTelemetry)
#   apps/server/src/observability/BrowserTraceCollector.ts
#   apps/server/src/provider/Layers/EventNdjsonLogger.ts (per-record budget, transient event filter)
#   docs/internals/providers.md (Provider diagnostics)
#   docs/internals/resource-telemetry.md
#   docs/user/telemetry.md

Feature: Node diagnostics
  The node reports what it and the processes it started are doing, so the user can find a
  runaway agent or terminal and stop it.

  Background:
    Given a running node that started a provider and a terminal

  @node
  Scenario: The node samples its process tree every fifteen seconds
    Given nobody watches the resource monitor
    Then the node samples the processes under it every fifteen seconds

  @node
  Scenario: Watching the resource monitor samples faster
    When a client follows the node's resource telemetry
    Then the node samples every two seconds
    And each sample is pushed to the client

  @node
  Scenario: The faster sampling ends when nobody watches
    Given a client follows the node's resource telemetry
    When it stops following
    Then the node goes back to sampling every fifteen seconds

  @node
  Scenario: The process list shows everything the node started
    When a client asks for the node's process diagnostics
    Then it lists the provider and the terminal with their CPU and memory

  @node
  Scenario: The node keeps an hour of resource history
    Given the node has run for two hours
    When a client asks for its resource telemetry history
    Then it receives the last hour of samples

  @node
  Scenario: A process's history is available on its own
    When a client asks for one process's resource history
    Then it receives that process's samples from the last hour

  @node
  Scenario: The node reports the host's resources
    When a client asks for the host's resources
    Then it receives the host's CPU count and memory

  @node
  Scenario: Retrying telemetry samples at once
    When a client asks the node to retry resource telemetry
    Then the node takes a sample immediately

  @node
  Scenario: I/O counters are reported as unavailable
    # The node reads I/O from /proc/<pid>/io; where that is missing it says so.
    When a client reads a process sample on a platform that does not count I/O
    Then its I/O is marked unavailable rather than zero

  @node
  Scenario: A client stops a runaway process
    Given the process list shows a provider process
    When a client signals that process to terminate
    Then the process stops

  @node
  Scenario: The node refuses to signal a process that is not its own
    When a client signals a process id that is not under the node
    Then the node refuses

  @node
  Scenario: The node refuses to signal a reused process id
    Given a process the client saw has exited and its id was reused
    When the client signals it with the start time it saw
    Then the node refuses because it is no longer the same process

  @node
  Scenario: Trace diagnostics say the node records no traces
    When a client asks for trace diagnostics
    Then the node answers that it does not record traces

  @node
  Scenario: The server config names the logs directory
    When a client reads the node's server config
    Then it names the directory the node writes its logs to
    And it says tracing export is off

  @node
  Scenario: The node records traces the user can inspect
    Given tracing is enabled on the node
    When a turn runs
    Then trace diagnostics list the turn's spans

  @node
  Scenario: The node accepts client spans
    Given client tracing is on
    When a client exports spans to its node
    Then the node accepts them instead of answering not found

  @node
  Scenario: The node forwards client spans to a configured collector
    Given an OTLP collector is configured on the node
    When client spans arrive
    Then the node forwards them to the collector

  @node
  Scenario: The node reports per-process I/O
    When a client reads a process sample on a platform that counts I/O
    Then the sample includes read and write bytes

  @node
  Scenario: A large provider payload is logged as a summary within 64 KiB
    Given provider event logging is on
    When a provider sends a response larger than 64 KiB or nested deeper than the log allows
    Then its log record is a structural summary of at most 64 KiB
    And the summary keeps the routing ids, method, status and error fields
    And the provider still receives and handles the full response

  @node
  Scenario: Streaming deltas are left out of provider event logs
    Given provider event logging is on
    When a provider streams text, command output and plan deltas
    Then the log keeps lifecycle events, responses and failures but not the deltas
