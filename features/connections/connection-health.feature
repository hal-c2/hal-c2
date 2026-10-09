# Sources:
#   docs/internals/connection-runtime.md (one retry owner, HTTP authorization, freshness)
#   docs/internals/environment-auth.md
#   packages/client-runtime/src/connection/supervisor.ts, registry.ts
#   packages/client-runtime/src/authorization/service.ts
#   packages/client-runtime/src/rpc/session.ts, rpc/client.ts
#   packages/client-runtime/src/state/threads.ts (five idle minutes of thread cache)
#   packages/client-runtime/src/connection/compatibility.ts (ConnectionBlockedError)
#   apps/web/src/versionSkew.ts (server older than the client, nightly comparison, dismissals)
#   apps/server-ex/lib/hal_c2/environment.ex (serverVersion in the descriptor)
#   packages/client-runtime/src/v3/clusterSocket.ts, v3/clusterMembers.ts, v3/session.ts
#   apps/web/src/components/settings/ConnectionsSettings.tsx ("Reconnecting: <reason>", Copy trace ID)
#   apps/mobile/src/features/connection/ConnectionStatusDot.tsx, connectionTone.ts,
#     EnvironmentConnectionNotice.tsx, ConnectionTraceId.tsx
#   apps/tui/src/connection.ts
#   apps/desktop-qt/src/native/ConnectionHealthController.cpp (the device's network: the system's
#     reachability held against its interfaces, hal-c2/hal-c2#69)
#   apps/tui/src/features.backlog.test.ts (environment-connections)
#   apps/desktop-qt/src/native/McClient.cpp, ThreadStore.cpp, ShellStore.cpp (each `sub` says where it resumes from)
#   Shared domain: tui/reconnect.feature holds the terminal client's reconnects;
#   mobile/offline-and-lifecycle.feature holds the phone's foreground and offline journeys;
#   mc/platform/websocket-protocol.feature holds resuming streams on the MC;
#   local-cache.feature holds what a client keeps between runs.

Feature: Connection health
  Each environment has one connection owner in a client. It retries transport failures with
  backoff, waits out offline and authorization problems, and keeps cached data readable
  without pretending to be live.

  Background:
    Given a client paired with an environment

  @desktop @mobile @backlog-mobile
  Scenario: A dropped connection retries with growing delays
    Given the environment stops answering
    When the connection drops
    Then the client retries with delays that grow up to a cap
    And reconnects when the environment answers again

  # Proved by tst_ShellExamples.cpp (the notice's place) and tst_ThreadView.qml (the thread
  # stays quiet), not yet by a step (hal-c2/hal-c2#145, #163).
  @desktop @backlog-desktop
  Scenario: A dropped connection is reported once, with one way to retry
    Given the user is reading a thread
    When the connection drops
    Then one notice says the environment is being reconnected, with one Try again
    And the thread does not say its MC cannot be reached
    And the notice covers neither the window controls, the header nor the thread

  @desktop @mobile @backlog-mobile
  Scenario: An offline device waits instead of retrying
    Given the device has no network
    When the connection drops
    Then the client waits for the network to return before trying again

  # Whether the device has a network is the system's word, held against its interfaces:
  # Android says disconnected when any one network is lost, the one a phone just left for
  # another included (hal-c2/hal-c2#69). Only an environment on another machine needs a
  # network, and which machine it is on is asked again whenever the client is opened.
  @desktop @mobile @backlog-mobile
  Scenario: A device that lost one of its two networks keeps trying
    Given the environment is on another machine
    And the environment stops answering
    When the device loses one of its two networks
    And the connection drops
    Then the client keeps retrying
    And does not say the device is offline

  @desktop @mobile @backlog-mobile
  Scenario: A device that lost every network waits and says it is offline
    Given the environment is on another machine
    When the device loses every network
    And the connection drops
    Then the client waits for the network
    And says the device is offline

  @desktop @mobile @backlog-mobile
  Scenario: A network that comes back is tried at once
    Given the environment is on another machine
    And the client is waiting for the network
    When a network comes back
    Then it tries again at once

  @desktop @mobile @backlog-mobile
  Scenario: An environment on this machine is reached without a network
    Given the environment is on another machine
    And the client is waiting for the network
    When the user pairs the client with an environment on this machine
    Then it connects at once

  @desktop @mobile @backlog-mobile
  Scenario: A client opened without a network waits for it
    Given the device loses every network
    When the client is opened at an environment on another machine
    Then the client waits for the network
    And says the device is offline

  @desktop @mobile @backlog-mobile
  Scenario: A refused credential waits for the user
    Given the environment refuses the client's credential
    When the client connects
    Then the client stops retrying
    And asks the user to pair again

  @backlog @desktop @mobile
  Scenario: Only the environment with the bad credential stops
    Given two paired environments
    And one of them revoked this client
    When the client connects to both
    Then the other environment stays connected

  @desktop @mobile @backlog-mobile
  Scenario: Foregrounding wakes a waiting retry
    Given the client is waiting to retry
    When the app comes to the foreground
    Then it tries again at once

  @desktop @mobile @backlog-mobile
  Scenario: Foregrounding probes a healthy connection instead of replacing it
    Given an established connection
    When the app comes to the foreground after a moment
    Then the client checks the connection
    And keeps it when it answers

  @backlog @mobile
  Scenario: A long background suspension replaces the connection
    Given the app was suspended for a long time
    When it comes to the foreground
    Then the client opens a new connection without waiting for the old one to fail

  @desktop @mobile @backlog-mobile
  Scenario: A connection is ready only after the environment describes itself
    When the socket opens
    Then the client reports connecting until the environment's configuration arrives

  @desktop @mobile @backlog-mobile
  Scenario: A failed shell subscription is not shown as reconnecting
    Given a connected environment
    When its shell subscription fails
    Then the client reports the data problem
    And does not claim to be reconnecting

  @desktop @mobile @backlog-mobile
  Scenario: The environment's status names why it is reconnecting
    Given the connection dropped because of a timeout
    Then the environment reads "Reconnecting: timeout"

  @desktop @mobile @backlog-mobile
  Scenario: The user copies a connection's trace id for a bug report
    Given a connection that failed
    When the user copies its trace id
    Then the trace id is on the clipboard

  @desktop @mobile @backlog-mobile
  Scenario: Cached data stays readable offline without looking live
    Given threads were loaded before the connection dropped
    When the user opens one offline
    Then the thread shows its cached content
    And the client does not claim a live connection

  @backlog @desktop @mobile
  Scenario: Cached data never overwrites newer live data
    Given the client reconnects while cached data loads
    When live data arrives first
    Then the older cached data is not applied over it

  @desktop @mobile @backlog-mobile
  Scenario: A thread left for under five minutes resumes without a snapshot
    Given the user left a thread
    When the user returns within five minutes
    Then the client resumes the thread from where it stopped

  @desktop @mobile @backlog-mobile
  Scenario: A thread left for longer comes back from what the client kept
    Given the user left a thread more than five minutes ago
    And the agent answered "Shipping is next." meanwhile
    When the user returns
    Then the client asks for the thread from where its copy stands
    And the MC sends only what the client lacks
    And the thread shows "Shipping is next." after the conversation it kept

  @desktop @mobile @backlog-mobile
  Scenario: Subscriptions follow a replaced connection
    Given a client subscribed to a thread
    When the connection is replaced
    Then the subscription continues on the new connection

  @desktop @mobile @backlog-mobile
  Scenario: Reconnecting does not repeat the user's actions
    Given the user sent a command just before the connection dropped
    When the client reconnects
    Then the command is not sent again automatically

  @backlog @desktop @mobile
  Scenario: An expiring credential does not close a healthy connection
    Given a connected client whose credential is about to expire
    When the client renews it for an HTTP request
    Then the connection stays open

  @backlog @desktop @mobile
  Scenario: A failed renewal affects only its request
    Given a connected client
    When renewing its credential fails for an HTTP request
    Then only that request fails
    And the connection stays open

  @desktop @mobile @backlog-mobile
  Scenario: Removing an environment clears everything the client kept for it
    Given a saved environment with cached threads and drafts
    When the user removes it
    Then its credential, cached data and drafts are cleared

  @backlog @desktop @mobile
  Scenario: Signing out of HAL-C2 Connect keeps directly paired environments
    Given one relayed and one directly paired environment
    When the user signs out of HAL-C2 Connect
    Then the directly paired environment stays

  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A protocol mismatch blocks the connection with advice
    Given an environment whose MC speaks <protocol>
    When the client connects
    Then the connection is blocked
    And the client says <advice>

    Examples:
      | protocol                       | advice                                   |
      | a newer protocol than the client | update HAL-C2 on this device          |
      | an older protocol than the client | update HAL-C2 on that environment    |

  # A different app version does not block the connection; only a server behind the client
  # warns. settings/updates.feature holds updating the server from that warning and keeping
  # a dismissed notice dismissed for its version.
  @shared @backlog-mobile
  Scenario Outline: A server on another HAL-C2 version warns only when it is behind
    Given this client runs HAL-C2 <client>
    And the environment's MC runs HAL-C2 <server>
    When the client connects
    Then the connection is used as normal
    And the client <warning>

    Examples:
      | client                 | server                 | warning                     |
      | 1.4.0                  | 1.3.2                  | warns of a version mismatch |
      | 1.3.2                  | 1.4.0                  | does not warn               |
      | 1.4.0                  | 1.4.0-nightly.20260901 | does not warn               |
      | 1.4.0-nightly.20260902 | 1.4.0-nightly.20260901 | warns of a version mismatch |

  @shared @backlog-mobile @backlog-tui
  Scenario: One connection serves every MC of a cluster
    Given a client connected to a cluster of three MCs
    Then the client keeps one connection for the cluster
    And streams from every MC arrive over it

  @shared @backlog-mobile @backlog-tui
  Scenario: A cluster connection resumes each stream from where it stopped
    Given a client following threads on two cluster members
    When the cluster connection drops and returns
    Then each thread stream resumes from its last offset
    And the thread list asks only for the rows changed since
