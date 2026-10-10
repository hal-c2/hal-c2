# Sources:
#   apps/server-ex/lib/hal_c2/diagnostics.ex (ps sampler, process list, telemetry, signalProcess, traces)
#   apps/server-ex/lib/hal_c2/environment.ex (server config observability, logs directory)
#   apps/server-ex/lib/hal_c2/web/socket.ex (resourceTelemetry shape)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (client-trace-forwarding)
#   apps/server/src/serverLogger.ts (log export to a configured logs endpoint)
#   packages/contracts/src/server.ts (server.getTraceDiagnostics, server.getProcessDiagnostics,
#     server.getHostResources, server.getProcessResourceHistory, server.getResourceTelemetryHistory,
#     server.retryResourceTelemetry, server.signalProcess, subscribeResourceTelemetry)
#   apps/server/src/observability/BrowserTraceCollector.ts
#   apps/server/src/cli/triage.ts, apps/server/src/cli/triagePrompt.ts (hal-c2 triage, kept identical to .github/triage/PLAYBOOK.md)
#   apps/server/src/observability/RpcInstrumentation.ts, Attributes.ts, Metrics.ts (request spans, outcomes, model labels)
#   apps/server/src/resourceTelemetry/HostResources.ts, ResourceTelemetryHistory.ts, Model.ts (host reading, history bounds, deltas, identity, lifecycle counters)
#   apps/server/src/provider/Layers/EventNdjsonLogger.ts (per-record budget, transient event filter, rotation, retention)
#   apps/server/src/provider/Layers/ProviderEventLoggers.ts, apps/server/src/provider/NativeProtocolLogging.ts
#   apps/server/src/provider/acp/AcpNativeLogging.ts (a failed log write never fails the session)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts, ClaudeAdapterV2.ts (what protocol logs leave out)
#   docs/internals/providers.md (Provider diagnostics)
#   docs/internals/resource-telemetry.md
#   docs/user/telemetry.md

Feature: MC diagnostics
  The MC reports what it and the processes it started are doing, so the user can find a
  runaway agent or terminal and stop it.

  Background:
    Given a running MC that started a provider and a terminal

  @mc
  Scenario: The MC samples its process tree every fifteen seconds
    Given nobody watches the resource monitor
    Then the MC samples the processes under it every fifteen seconds

  @mc
  Scenario: Watching the resource monitor samples faster
    When a client follows the MC's resource telemetry
    Then the MC samples every two seconds
    And each sample is pushed to the client

  @mc
  Scenario: The faster sampling ends when nobody watches
    Given a client follows the MC's resource telemetry
    When it stops following
    Then the MC goes back to sampling every fifteen seconds

  @mc
  Scenario: The process list shows everything the MC started
    When a client asks for the MC's process diagnostics
    Then it lists the provider and the terminal with their CPU and memory

  @mc
  Scenario: The MC keeps an hour of resource history
    Given the MC has run for two hours
    When a client asks for its resource telemetry history
    Then it receives the last hour of samples

  @mc
  Scenario: A process's history is available on its own
    When a client asks for one process's resource history
    Then it receives that process's samples from the last hour

  @mc
  Scenario: The MC reports the host's resources
    When a client asks for the host's resources
    Then it receives the host's CPU count and memory

  @mc
  Scenario: Retrying telemetry samples at once
    When a client asks the MC to retry resource telemetry
    Then the MC takes a sample immediately

  @mc
  Scenario: I/O counters are reported as unavailable
    # The MC reads I/O from /proc/<pid>/io; where that is missing it says so.
    When a client reads a process sample on a platform that does not count I/O
    Then its I/O is marked unavailable rather than zero

  @mc
  Scenario: A client stops a runaway process
    Given the process list shows a provider process
    When a client signals that process to terminate
    Then the process stops

  @mc
  Scenario: The MC refuses to signal a process that is not its own
    When a client signals a process id that is not under the MC
    Then the MC refuses

  @mc
  Scenario: The MC refuses to signal a reused process id
    Given a process the client saw has exited and its id was reused
    When the client signals it with the start time it saw
    Then the MC refuses because it is no longer the same process

  @mc
  Scenario: Trace diagnostics say the MC records no traces
    When a client asks for trace diagnostics
    Then the MC answers that it does not record traces

  @mc
  Scenario: The server config names the logs directory
    When a client reads the MC's server config
    Then it names the directory the MC writes its logs to
    And it says tracing export is off

  @mc
  Scenario: The MC records traces the user can inspect
    Given tracing is enabled on the MC
    When a turn runs
    Then trace diagnostics list the turn's spans

  # Legacy: apps/server/src/observability/RpcInstrumentation.ts (RPC_SPAN_PREFIX, DEFAULT_RPC_SPAN_ATTRIBUTES)
  @backlog @mc
  Scenario: Each request a client makes is a span naming its method
    Given tracing is enabled on the MC
    When a client makes a request over its connection
    Then trace diagnostics list a span "ws.rpc.<method>" for it
    And the span says the request came over a websocket

  # Legacy: apps/server/src/observability/RpcInstrumentation.ts (RPC_METHODS_WITH_TRACING_DISABLED)
  @backlog @mc
  Scenario: Reading diagnostics does not fill the trace with its own requests
    Given tracing is enabled on the MC
    When a client reads trace diagnostics, process diagnostics or a process's resource history, or signals a process
    Then those requests leave no spans
    And other requests still do

  # Legacy: apps/server/src/observability/RpcInstrumentation.ts (observeRpcEffect, observeRpcStream), Attributes.ts (outcomeFromExit)
  @backlog @mc
  Scenario Outline: Requests are counted by how they ended
    When a client's request <ending>
    Then the MC counts it with the outcome "<outcome>"
    And its duration is recorded

    Examples:
      | ending                                        | outcome   |
      | is answered                                   | success   |
      | fails                                         | failure   |
      | is stopped because the client left            | interrupt |
      | is a subscription that ends with an error     | failure   |

  # Legacy: apps/server/src/observability/Attributes.ts (normalizeModelMetricLabel), Metrics.ts
  @backlog @mc
  Scenario Outline: Metrics name a model's family, never the model
    When a turn runs on the model "<model>"
    Then its metrics carry the model label "<label>"

    Examples:
      | model              | label  |
      | gpt-5.4            | gpt    |
      | Claude-Opus-4      | claude |
      | gemini-2.5-pro     | gemini |
      | grok-build         | other  |

  # Legacy: apps/server/src/resourceTelemetry/HostResources.ts (sample: two readings 200 ms apart)
  # Likely already implemented: apps/server-ex/lib/hal_c2/diagnostics.ex (host CPU use)
  @backlog @mc
  Scenario Outline: Host CPU use is measured over a short interval or left blank
    Given the host's CPU counters <state>
    When a client asks for the host's resources
    Then CPU use is <reported>

    Examples:
      | state                                              | reported                              |
      | advance between two readings a moment apart        | the share of that interval not idle   |
      | did not advance                                    | left blank                            |
      | belong to a different number of cores than before  | left blank                            |

  # Legacy: apps/server/src/resourceTelemetry/HostResources.ts (MemAvailable, vm_stat, clamp to total)
  @backlog @mc
  Scenario: Available memory is what the host says can be used without swapping
    When a client asks for the host's resources
    Then available memory is the figure the operating system reports as available, not merely free
    And it is never above the host's total memory

  # Legacy: apps/server/src/resourceTelemetry/HostResources.ts (Cache with a five second TTL)
  @backlog @mc
  Scenario: Many clients asking for the host's resources cause one reading
    Given three clients ask for the host's resources within five seconds
    Then the host is read once and all three get that reading

  # Legacy: apps/server/src/resourceTelemetry/ResourceTelemetryHistory.ts (normalizeResourceTelemetryHistoryInput)
  # Likely already implemented: apps/server-ex/lib/hal_c2/diagnostics.ex (history)
  @backlog @mc
  Scenario Outline: A history request is held to what the MC keeps
    When a client asks for resource history over <window> in buckets of <bucket>
    Then the history covers <window used> in buckets of <bucket used>

    Examples:
      | window     | bucket     | window used | bucket used |
      | 3 hours    | 1 minute   | 1 hour      | 1 minute    |
      | 100 ms     | 100 ms     | 1 second    | 1 second    |
      | 10 minutes | 1 hour     | 10 minutes  | 10 minutes  |
      | 10 minutes | 10 ms      | 10 minutes  | 1 second    |

  # Legacy: apps/server/src/resourceTelemetry/ResourceTelemetryHistory.ts (observed RSS, "uses observed RSS for the history-window peak")
  # Likely already implemented: apps/server-ex/lib/hal_c2/diagnostics.ex (peak)
  @backlog @mc
  Scenario: A process's peak memory in a history window is what was seen in that window
    Given a process whose memory reached 2 GiB an hour ago and has been 300 MiB since
    When a client asks for the last ten minutes of resource history
    Then that process's peak memory for the window is 300 MiB

  # Legacy: apps/server/src/resourceTelemetry/ResourceTelemetryHistory.ts ("prorates a cumulative delta that crosses the history window boundary",
  #   "uses the preceding sample as a baseline without attributing pre-window deltas", "retains cumulative baselines while a process is absent")
  @backlog @mc
  Scenario Outline: CPU time and I/O in a history window count only what happened inside it
    Given a process whose counters were read before and during the window
    When a client asks for resource history over that window
    Then <counted>

    Examples:
      | counted                                                                                      |
      | what the process did before the window started is not attributed to the window               |
      | a reading that straddles the window's start is shared out by the time that falls inside      |
      | a process missing from one sample keeps its earlier reading as its baseline for the next     |

  # Legacy: apps/server/src/resourceTelemetry/Model.ts (delta, MAX_DELTA_INTERVAL_MS)
  # Likely already implemented: apps/server-ex/lib/hal_c2/diagnostics.ex (rates)
  @backlog @mc
  Scenario Outline: A process's CPU time and I/O are counted as differences between samples
    Given a process with a reading of <earlier> and then a reading of <later> taken <apart>
    Then the interval adds <added>

    Examples:
      | earlier | later | apart       | added       |
      | 100     | 160   | 5 seconds   | 60          |
      | 160     | 100   | 5 seconds   | nothing     |
      | 100     | 160   | 90 seconds  | nothing     |

  # Legacy: apps/server/src/resourceTelemetry/Model.ts (processIdentityKey: pid and start time)
  # Likely already implemented: apps/server-ex/lib/hal_c2/diagnostics.ex (identity)
  @backlog @mc
  Scenario: A process that reuses an id is a new process
    Given a process was sampled and then exited
    And a new process took the same id with a different start time
    When the MC takes the next sample
    Then the new process is counted from zero rather than as a continuation of the old one

  # Legacy: apps/server/src/resourceTelemetry/Model.ts (processStarts, processExits per group)
  # The MC reports 0 for both today (diagnostics.ex).
  @backlog @mc
  Scenario: The monitor counts the processes it saw start and exit
    Given the MC saw an agent process start and exit between two samples
    When a client reads the resource telemetry
    Then the backend group shows one start and one exit
    And the total across everything HAL-C2 runs shows them too

  # Legacy: apps/server/src/resourceTelemetry/Model.ts (tree ordering by depth then id)
  @backlog @mc
  Scenario: The process list is ordered as a tree
    Given the MC started a provider that started two helpers
    When a client asks for the MC's process diagnostics
    Then each process is listed right after its parent, followed by that process's own children
    And a process's children are ordered by id
    And a process whose parent is not in the list is placed after the trees that are

  # Likely already implemented: apps/server-ex/lib/hal_c2/traces.ex (@max_bytes, @max_files)
  @backlog @mc
  Scenario: The trace file rolls over at 10 MiB and keeps ten older files
    Given tracing is enabled on the MC
    When the trace file reaches 10 MiB
    Then it moves aside as the newest backup and the oldest backup is dropped
    And the MC keeps writing to a new trace file

  @mc
  Scenario: The MC accepts client spans
    Given client tracing is on
    When a client exports spans to its MC
    Then the MC accepts them instead of answering not found

  @mc
  Scenario: The MC forwards client spans to a configured collector
    Given an OTLP collector is configured on the MC
    When client spans arrive
    Then the MC forwards them to the collector

  # The MC's own spans and metrics are not exported to a collector yet; only client spans are forwarded.
  @backlog @mc
  Scenario: The MC sends its own spans and metrics to a configured collector
    Given an OTLP collector is configured for traces and metrics on the MC
    When a turn runs and the MC's metrics are sampled
    Then the collector receives the MC's spans and metrics

  @backlog @mc
  Scenario: The MC sends its log records to a configured logs endpoint
    Given a logs endpoint is configured on the MC
    When the MC writes log records
    Then the endpoint receives them in the format and with the headers it asked for

  @backlog @mc
  Scenario: The MC stays off the network when no logs endpoint is configured
    Given no logs endpoint is configured on the MC
    When the MC writes log records
    Then nothing is sent anywhere
    And log messages are still attached to the active trace span

  @backlog @mc
  Scenario: Exported log records are not duplicated onto spans
    Given a logs endpoint is configured on the MC
    When the MC writes log records during a traced operation
    Then the records are exported once
    And the same messages are not also copied onto the span

  @mc
  Scenario: The MC reports per-process I/O
    When a client reads a process sample on a platform that counts I/O
    Then the sample includes read and write bytes

  @mc
  Scenario: A large provider payload is logged as a summary within 64 KiB
    Given provider event logging is on
    When a provider sends a response larger than 64 KiB or nested deeper than the log allows
    Then its log record is a structural summary of at most 64 KiB
    And the summary keeps the routing ids, method, status and error fields
    And the provider still receives and handles the full response

  @mc
  Scenario: Streaming deltas are left out of provider event logs
    Given provider event logging is on
    When a provider streams text, command output and plan deltas
    Then the log keeps lifecycle events, responses and failures but not the deltas

  # Rotation and retention of apps/server/src/provider/Layers/EventNdjsonLogger.ts
  # (10 MiB a file, ten files a thread, 512 MiB and 14 days in all). The MC's provider_log.ex
  # appends to one file per thread and neither rotates nor prunes it.
  @backlog @mc
  Scenario: Provider event logs rotate at 10 MiB and keep ten files for each thread
    Given provider event logging is on
    When a thread's provider log passes 10 MiB
    Then the log continues in a new file for that thread
    And at most ten files are kept for that thread, the oldest dropped first

  @backlog @mc
  Scenario: Old and excess provider event logs are removed
    Given provider event logging is on
    And the provider logs hold files older than 14 days and more than 512 MiB in all
    When the MC checks the provider logs
    Then files older than 14 days are removed
    And the oldest files are removed until the logs fit in 512 MiB
    And the file a thread is still writing to is kept

  @backlog @mc
  Scenario: Provider events outside any thread share one log
    Given provider event logging is on
    When a provider sends an event that belongs to no thread
    Then the event is written to the shared provider log

  @backlog @mc
  Scenario: Provider event logging that cannot start does not stop the MC
    Given provider event logging is on
    And the provider log folder cannot be created
    When the MC starts
    Then the MC starts without provider event logging
    And a warning says why

  @backlog @mc
  Scenario: A provider event that cannot be logged does not fail the agent's session
    Given provider event logging is on
    And an ACP agent is running a turn
    When writing one of its events to the log fails
    Then the turn carries on
    And the MC logs a warning about the write

  @backlog @mc
  Scenario: Provider event logs hold HAL-C2's own events beside the provider's
    Given provider event logging is on
    When a provider runs a turn
    Then the log holds the events as the provider sent them
    And the events HAL-C2 made of them

  @backlog @mc
  Scenario: A running tool's growing output is logged once it settles
    Given provider event logging is on
    When a provider reports a tool's output growing while the tool runs
    Then the log keeps the tool's start and its final result
    And not each intermediate snapshot

  @backlog @mc
  Scenario: Raw frames are not logged when their decoded form is
    Given provider event logging is on
    When a provider's raw frame is decoded
    Then the log keeps the decoded frame
    And a frame that failed to decode is logged as a failure

  # CodexAdapterV2.ts redactCodexProtocolValue, ClaudeAdapterV2.ts (query options logged
  # without env, MCP server headers or callbacks).
  @backlog @mc @plugin-codex
  Scenario Outline: Codex protocol logs never hold credentials
    Given provider event logging is on
    When a Codex protocol message carries <content>
    Then the log shows "[REDACTED]" in its place

    Examples:
      | content                                                                     |
      | a value that starts with "Bearer "                                          |
      | a field whose name ends in authorization, apikey, token, password or secret |
      | either of those inside JSON carried as text                                 |

  @backlog @mc @plugin-claude
  Scenario: Claude's logged start-up options leave out its environment and credentials
    Given provider event logging is on
    When a Claude session starts with the "hal-c2" server attached
    Then the logged options name the model, mode and working folder
    And they hold no environment values and no credential for the "hal-c2" server

  # The triage command is run by an operator next to an installed HAL-C2, with or without an
  # MC running.
  @backlog @mc
  Scenario: The triage command writes a context file and a prompt for an agent to investigate
    When the operator runs "hal-c2 triage"
    Then a new folder under the triage reports holds "context.md" and "prompt.md"
    And the context names the HAL-C2 version, its release tag, the operating system and the launch command
    And the context says whether an MC is running, naming the dead process when its state file is stale
    And the context lists the folders HAL-C2 keeps its files in

  @backlog @mc
  Scenario: The triage command hands the prompt to the one agent that is installed
    Given only the Claude command-line agent is installed
    When the operator runs "hal-c2 triage"
    Then Claude opens interactively in the triage folder with the prompt
    And the triage command exits with Claude's exit status

  @backlog @mc
  Scenario: The triage command can pass a model to the agent
    Given only the Codex command-line agent is installed
    When the operator runs "hal-c2 triage --model gpt-5"
    Then Codex opens with the model "gpt-5"

  @backlog @mc
  Scenario: With two agents installed the triage command asks which to use
    Given both Claude and Codex are installed
    And the operator is at a terminal
    When the operator runs "hal-c2 triage"
    Then the operator is asked which agent to use

  @backlog @mc
  Scenario: With two agents installed and no terminal the triage command asks for a choice up front
    Given both Claude and Codex are installed
    And there is no terminal to ask on
    When the operator runs "hal-c2 triage"
    Then the command fails saying to re-run with an agent named

  @backlog @mc
  Scenario: Naming an agent that is not installed fails
    Given Codex is not installed
    When the operator runs "hal-c2 triage --agent codex"
    Then the command fails saying "codex" is not installed or was not found on the path

  @backlog @mc
  Scenario: With no agent installed the triage files are left to paste into any agent
    Given neither Claude nor Codex is installed
    When the operator runs "hal-c2 triage"
    Then the command says where "prompt.md" and "context.md" were written
    And it says to paste the prompt into an agent of the operator's choice

  @backlog @mc
  Scenario: The triage prompt investigates without changing the installation or filing on its own
    When the agent follows the triage prompt
    Then it asks the user what went wrong before looking
    And it reads the source at the installed release tag, not the latest source
    And it does not patch the installed source
    And it files a report only after the user explicitly agrees
