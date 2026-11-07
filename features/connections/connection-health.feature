# Sources:
#   https://github.com/pingdotgg/t3code/pull/14518
#   https://github.com/pingdotgg/t3code/pull/20441
#   https://github.com/pingdotgg/t3code/pull/16200
#   https://github.com/pingdotgg/t3code/pull/13083
#   https://github.com/pingdotgg/t3code/pull/13577
#   https://github.com/pingdotgg/t3code/pull/13683 (a slow snapshot is given time before a second load)
#   apps/web/src/hooks/useEnvironmentDisconnectDelay.ts (20 seconds before a thread offers to disconnect), apps/web/src/components/ChatView.tsx (disconnect, reconnect)
#   docs/internals/connection-runtime.md (one retry owner, HTTP authorization, freshness)
#   docs/internals/environment-auth.md
#   packages/client-runtime/src/connection/supervisor.ts, registry.ts
#   packages/client-runtime/src/authorization/service.ts
#   packages/client-runtime/src/rpc/session.ts, rpc/client.ts
#   packages/client-runtime/src/state/threads.ts (five idle minutes of thread cache)
#   packages/client-runtime/src/connection/compatibility.ts (ConnectionBlockedError)
#   packages/client-runtime/src/connection/errors.ts (blocked or transient by the environment's answer, identity mismatch)
#   apps/desktop-qt/src/native/EnvironmentCatalog.cpp, SavedEnvironmentsController.cpp, McClient.cpp (saved environments, renewal)
#   apps/web/src/versionSkew.ts (server older than the client, nightly comparison, dismissals)
#   apps/web/src/connection/storage.ts (corrupt catalog quarantined, secure storage declining a write)
#   apps/server-ex/lib/hal_c2/environment.ex (serverVersion in the descriptor)
#   packages/client-runtime/src/v3/clusterSocket.ts, v3/clusterMembers.ts, v3/session.ts
#   apps/web/src/components/settings/ConnectionsSettings.tsx ("Reconnecting: <reason>", Copy trace ID)
#   apps/web/src/rpc/requestLatencyState.ts (requests unanswered for 15 s; 2 min for provider and
#     server updates; pull request and subscribe methods untracked)
#   apps/web/src/components/SlowRpcRequestToastCoordinator.tsx ("Some requests are slow" warning)
#   apps/mobile/src/features/connection/ConnectionStatusDot.tsx, connectionTone.ts,
#     EnvironmentConnectionNotice.tsx, ConnectionTraceId.tsx
#   apps/tui/src/connection.ts
#   apps/desktop-qt/src/native/ConnectionHealthController.cpp (the device's network: the system's
#     reachability held against its interfaces, hal-c2/hal-c2#69)
#   apps/tui/src/features.backlog.test.ts (environment-connections)
#   apps/desktop-qt/src/native/McClient.cpp, ThreadStore.cpp, ShellStore.cpp (each `sub` says where it resumes from)
#   https://github.com/pingdotgg/t3code/pull/14897
#   https://github.com/pingdotgg/t3code/pull/15034
#   Shared domain: tui/reconnect.feature holds the terminal client's reconnects;
#   mobile/offline-and-lifecycle.feature holds the phone's foreground and offline journeys;
#   mc/platform/websocket-protocol.feature holds resuming streams on the MC;
#   local-cache.feature holds what a client keeps between runs.
#   https://github.com/pingdotgg/t3code/pull/15470
#   https://github.com/pingdotgg/t3code/pull/15563

Feature: Connection health
  Each environment has one connection owner in a client. It retries transport failures with
  backoff, waits out offline and authorization problems, and keeps cached data readable
  without pretending to be live.

  Background:
    Given a client paired with an environment

  @desktop @mobile
  Scenario: A dropped connection retries with growing delays
    Given the environment stops answering
    When the connection drops
    Then the client retries with delays that grow up to a cap
    And reconnects when the environment answers again

  @desktop
  Scenario: A dropped connection is reported once, with one way to retry
    Given the user is reading a thread
    When the connection drops
    Then one notice says the environment is being reconnected, with one Try again
    And the thread does not say its MC cannot be reached
    And the notice covers neither the window controls, the header nor the thread

  @desktop
  Scenario: A shell of the user's that uses the built-in layout reports a dropped connection once
    Given the user's shell fills its window with the built-in layout
    When the connection drops
    Then one notice says the environment is being reconnected

  @desktop @mobile
  Scenario: An offline device waits instead of retrying
    Given the device has no network
    When the connection drops
    Then the client waits for the network to return before trying again

  # Whether the device has a network is the system's word, held against its interfaces:
  # Android says disconnected when any one network is lost, the one a phone just left for
  # another included (hal-c2/hal-c2#69). Only an environment on another machine needs a
  # network, and which machine it is on is asked again whenever the client is opened.
  @desktop @mobile
  Scenario: A device that lost one of its two networks keeps trying
    Given the environment is on another machine
    And the environment stops answering
    When the device loses one of its two networks
    And the connection drops
    Then the client keeps retrying
    And does not say the device is offline

  @desktop @mobile
  Scenario: A device that lost every network waits and says it is offline
    Given the environment is on another machine
    When the device loses every network
    And the connection drops
    Then the client waits for the network
    And says the device is offline

  @desktop @mobile
  Scenario: A network that comes back is tried at once
    Given the environment is on another machine
    And the client is waiting for the network
    When a network comes back
    Then it tries again at once

  @desktop @mobile
  Scenario: An environment on this machine is reached without a network
    Given the environment is on another machine
    And the client is waiting for the network
    When the user pairs the client with an environment on this machine
    Then it connects at once

  @desktop @mobile
  Scenario: A client opened without a network waits for it
    Given the device loses every network
    When the client is opened at an environment on another machine
    Then the client waits for the network
    And says the device is offline

  @desktop @mobile
  Scenario: A refused credential waits for the user
    Given the environment refuses the client's credential
    When the client connects
    Then the client stops retrying
    And asks the user to pair again

  @desktop @mobile
  Scenario: Only the environment with the bad credential stops
    Given two paired environments
    And one of them revoked this client
    When the client connects to both
    Then the other environment stays connected

  # Legacy: packages/client-runtime/src/connection/errors.ts (mapRemoteEnvironmentError)
  @desktop @mobile
  Scenario Outline: What the environment answers decides whether the client keeps trying
    Given the client is connecting to an environment
    When <answer>
    Then the client <action>
    And the status says "<message>"

    Examples:
      | answer                                                     | action             | message                                                       |
      | the environment says the credential is invalid             | stops retrying     | The environment credential is invalid.                        |
      | the credential lacks a scope the connection needs          | stops retrying     | The environment credential does not grant the required access. |
      | the environment rejects the authentication request         | stops retrying     | The environment rejected the authentication request.          |
      | the environment has no such authentication endpoint        | stops retrying     | The environment endpoint could not be found.                  |
      | the environment answers with an internal error             | keeps retrying     | The environment could not authorize the connection.           |
      | the environment answers with something that is not a reply | keeps retrying     | Remote environment endpoint returned an invalid response.     |

  # Legacy: packages/client-runtime/src/connection/errors.ts (environmentMismatchError)
  @desktop @mobile
  Scenario: An address that answers as a different environment is not used
    Given "studio" was saved at an address
    And a different environment now answers at that address
    When the client connects
    Then the connection is blocked
    And the status says the connected environment does not match the saved one
    And the client does not keep retrying

  # Legacy: packages/client-runtime/src/connection/errors.ts (profileMissingError, credentialMissingError)
  @desktop @mobile
  Scenario Outline: A saved environment whose record or credential has gone is blocked, not retried
    Given "studio" is saved but <missing>
    When the client connects
    Then the connection is blocked
    And the status says "<message>"

    Examples:
      | missing                       | message                                       |
      | its connection record is gone | Connection profile studio is unavailable.     |
      | its credential is gone        | Connection credential studio is unavailable.  |

  @desktop @mobile
  Scenario: Foregrounding wakes a waiting retry
    Given the client is waiting to retry
    When the app comes to the foreground
    Then it tries again at once

  @desktop @mobile
  Scenario: Foregrounding probes a healthy connection instead of replacing it
    Given an established connection
    When the app comes to the foreground after a moment
    Then the client checks the connection
    And keeps it when it answers

  # Legacy: packages/client-runtime/src/connection/supervisor.ts (CONNECTION_PROBE_TIMEOUT, wakeProbeFailed)
  @desktop @mobile
  Scenario: A connection that does not answer the check on foregrounding is replaced at once
    Given an established connection that has silently died
    When the app comes to the foreground
    And the environment does not answer the check within 15 seconds
    Then the client opens a new connection without waiting out a retry delay
    But a second failure in a row goes back to the growing delays

  # Legacy: packages/client-runtime/src/connection/supervisor.ts (MOBILE_CONNECTION_PROBE_TIMEOUT)
  @mobile
  Scenario: The phone gives the foreground check 3 seconds, not 15
    Given an established connection that has silently died
    When the phone's app comes to the foreground
    Then the client gives up on the check after 3 seconds
    And the status says the environment did not respond to a connection health check

  # Legacy: packages/client-runtime/src/connection/supervisor.ts (CONNECTION_ESTABLISHMENT_TIMEOUT)
  @desktop @mobile
  Scenario: A connection that is not set up within 15 seconds counts as failed
    Given the environment accepts the connection but never finishes introducing itself
    When 15 seconds pass
    Then the attempt is abandoned and reported as a timeout
    And the client retries after the usual delay

  # Upstream #14518: a cold MC slow to build its first snapshot was torn down and retried in a loop.
  @backlog @desktop @mobile
  Scenario: A connection that is open but slow to send its first snapshot is kept
    Given the environment's socket opened and its first snapshot takes 40 seconds to arrive
    When the client connects
    Then the connection is kept and is ready once the snapshot arrives
    And the attempt is given up only after 75 seconds more than the setup time
    And a route that fails while waiting for its snapshot leaves the next route its own time

  # Legacy: packages/client-runtime/src/connection/supervisor.ts (BACKOFF_RESET_AFTER_MS)
  @desktop @mobile
  Scenario Outline: The retry delays start over only after a connection has held for 30 seconds
    Given the client has already failed to connect several times
    And it connects
    When the connection drops after <held>
    Then the next retry waits <delay>

    Examples:
      | held       | delay                                  |
      | 40 seconds | the shortest delay                     |
      | 5 seconds  | the next longer delay than before      |

  # Legacy: packages/client-runtime/src/connection/supervisor.ts (blocked phase, waitForSignal)
  @desktop @mobile
  Scenario: A blocked environment is tried again when the app returns to the foreground
    Given the environment refuses the client's credential
    And the client stopped retrying
    When the app comes to the foreground
    Then the client tries to connect once more
    And stays blocked with the same reason if the environment still refuses

  @mobile
  Scenario: A long background suspension replaces the connection
    Given the app was suspended for a long time
    When it comes to the foreground
    Then the client opens a new connection without waiting for the old one to fail

  @desktop @mobile
  Scenario: A connection is ready only after the environment describes itself
    When the socket opens
    Then the client reports connecting until the environment's configuration arrives

  @desktop @mobile
  Scenario: A failed shell subscription is not shown as reconnecting
    Given a connected environment
    When its shell subscription fails
    Then the client reports the data problem
    And does not claim to be reconnecting

  # The client's own reason for a drop ("timeout", "HTTP 502", a socket error) goes to its
  # log under the attempt's trace id; the user reads a sentence.
  @desktop @mobile
  Scenario: The environment's status says it is reconnecting, in plain words
    Given the connection dropped because of a timeout
    Then the environment reads "Reconnecting"
    And the notice says why: "It stopped answering. HAL-C2 keeps trying."
    And no surface shows the client's own reason "timeout"

  # The window shows its connection as an icon and a word; hovering it says what is going
  # on, and clicking it opens a panel with the sentence and what the user can do.
  @desktop @mobile
  Scenario Outline: The connection's state is an icon with a word
    Given the connection is <state>
    Then the window shows the <icon> icon with "<word>"
    And hovering it says what is going on

    Examples:
      | state                   | icon          | word           |
      | connecting              | circle-dashed | Connecting     |
      | retrying after a drop   | refresh-cw    | Reconnecting   |
      | waiting for the network | cloud         | Offline        |
      | refused its credential  | lock          | Needs pairing  |
      | on another protocol     | octagon-alert | Update needed  |

  # Shown only once a reconnect is a second and a half old; most are over by then. What
  # needs the user (pairing, an update, no network) is shown at once.
  # The terminal client holds back its "reconnecting" line the same way (tui/reconnect.feature).
  @desktop @mobile
  Scenario: A reconnect within a second and a half is not shown
    Given a connected environment
    When the connection drops and comes back at once
    Then no surface said the connection was down

  # The grace is a reconnect's. An app that has not connected since it started says so at
  # once, in the window and in Connections settings, however long the environment takes.
  @desktop @mobile
  Scenario: An app that starts with its environment out of reach says so at once
    Given the environment takes no connections
    When the app starts and connects to it
    Then within a second and a half the window shows it is not connected
    And nothing said it was connected

  @desktop @mobile
  Scenario: The user copies a connection's trace id for a bug report
    Given a connection that failed
    When the user copies its trace id
    Then the trace id is on the clipboard

  @desktop
  Scenario: A request the MC has not answered within 15 seconds is listed in a warning
    Given the client is connected to the MC
    When a request to the MC is not answered for 15 seconds
    Then the user sees a "warning" toast "Some requests are slow" saying "1 request waiting longer than 15s."
    When 5 minutes pass
    Then the warning is still shown until the request is answered

  @desktop
  Scenario: The slow-request warning lists each waiting request and when it started
    Given two requests to the MC have not been answered for 15 seconds
    When the user shows the requests in the warning
    Then the warning lists each request by its method and environment
    And says when each request started

  @desktop
  Scenario: Answered requests leave the slow-request warning, which closes when none are waiting
    Given two requests to the MC have not been answered for 15 seconds
    When one of them is answered
    Then the warning says "1 request waiting longer than 15s."
    When the other is answered
    Then the warning is gone

  @desktop
  Scenario: Updating a provider or the server is reported as slow only after two minutes
    Given the user updates a provider
    When 1 minute and 59 seconds pass
    Then the user sees no warning
    When 1 more second passes
    Then the user sees a "warning" toast "Some requests are slow"

  @desktop
  Scenario: Pull request lookups and live subscriptions are never reported as slow
    When a pull request lookup is not answered for 5 minutes
    And a live subscription is not answered for 5 minutes
    Then the user sees no warning

  @desktop @mobile
  Scenario: Cached data stays readable offline without looking live
    Given threads were loaded before the connection dropped
    When the user opens one offline
    Then the thread shows its cached content
    And the client does not claim a live connection

  @desktop @mobile
  Scenario: Cached data never overwrites newer live data
    Given the client reconnects while cached data loads
    When live data arrives first
    Then the older cached data is not applied over it

  # Legacy: packages/client-runtime/src/platform/orchestrationCache.ts (decodeOrDiscardOrchestrationCache)
  @desktop @mobile
  Scenario: A kept copy the client cannot read is dropped and never blocks live data
    Given the client kept a copy of "Fix checkout" that it can no longer read
    When the user opens "Fix checkout" while connected
    Then the kept copy is removed
    And "Fix checkout" loads from the MC as if nothing had been kept

  # Legacy: packages/client-runtime/src/platform/persistence.ts (EnvironmentCacheStore.loadServerConfig)
  @desktop @mobile
  Scenario: A new task offline still offers the models the environment last reported
    Given "studio" last reported the models "Claude Sonnet" and "GPT-5"
    And "studio" is not reachable
    When the user starts a new task for "studio"
    Then "Claude Sonnet" and "GPT-5" are offered

  # Legacy: packages/client-runtime/src/platform/persistence.ts (loadVcsRefs, clearVcsRefs)
  @desktop @mobile
  Scenario: Only the whole branch list of a repository is kept
    Given the user searched the branches of "hal-c2" for "fix"
    When the client keeps the branches of "hal-c2" for later
    Then the matches for "fix" are not kept
    And a branch picker opened offline never presents a partial list as the whole one

  # Legacy: packages/client-runtime/src/platform/persistence.ts (clearVcsRefs: refs are repository-wide)
  @desktop @mobile
  Scenario: A change to a repository's branches drops every kept branch list for it
    Given the client kept the branch list of "hal-c2" and of a worktree of "hal-c2"
    When a branch of "hal-c2" is created
    Then neither kept list is offered again until it is read anew

  # Upstream #13683: a slow but alive MC finishes a load instead of being asked for it twice.
  @shared
  Scenario: A slow MC finishes the thread list instead of building it twice
    Given the MC takes 12 seconds to build the thread list
    When the client connects
    Then the thread list shows once the MC answers
    And the MC builds the thread list once

  @shared
  Scenario: A slow MC finishes opening a thread instead of loading it twice
    Given the MC takes 12 seconds to load a thread
    When the user opens the thread
    Then the thread shows once the MC answers
    And the MC loads the thread once

  @desktop @mobile
  Scenario: A thread left for under five minutes resumes without a snapshot
    Given the user left a thread
    When the user returns within five minutes
    Then the client resumes the thread from where it stopped

  @desktop @mobile
  Scenario: A thread left for longer comes back from what the client kept
    Given the user left a thread more than five minutes ago
    And the agent answered "Shipping is next." meanwhile
    When the user returns
    Then the client asks for the thread from where its copy stands
    And the MC sends only what the client lacks
    And the thread shows "Shipping is next." after the conversation it kept

  @desktop @mobile
  Scenario: Subscriptions follow a replaced connection
    Given a client subscribed to a thread
    When the connection is replaced
    Then the subscription continues on the new connection

  # Legacy: packages/client-runtime/src/rpc/client.ts (currentSession)
  @desktop @mobile
  Scenario: An action for an environment that is not connected fails by its name
    Given "studio" is offline
    When the user asks "studio" to do something
    Then the user is told "studio is not connected."
    And the request is not queued for later

  # Legacy: packages/client-runtime/src/v3/clusterSocket.ts (ping interval, calls rejected on close)
  @desktop @mobile
  Scenario: A connection with nothing to say is kept alive every 25 seconds
    Given a connected client with nothing open that streams
    When 25 seconds pass
    Then the client has pinged the MC

  # Legacy: packages/client-runtime/src/v3/clusterSocket.ts (onClose rejects pending calls)
  @desktop @mobile
  Scenario: An action waiting for its answer fails when the connection drops
    Given the user asked "studio" to do something and it has not answered
    When the connection to "studio" drops
    Then the action fails as disconnected
    And it is not sent again on the new connection

  @desktop @mobile
  Scenario: Reconnecting does not repeat the user's actions
    Given the user sent a command just before the connection dropped
    When the client reconnects
    Then the command is not sent again automatically

  @desktop @mobile
  Scenario: An expiring credential does not close a healthy connection
    Given a connected client whose credential is about to expire
    When the client renews it for an HTTP request
    Then the connection stays open

  @desktop @mobile
  Scenario: A failed renewal affects only its request
    Given a connected client
    When renewing its credential fails for an HTTP request
    Then only that request fails
    And the connection stays open

  @desktop @mobile
  Scenario: Removing an environment clears everything the client kept for it
    Given a saved environment with cached threads and drafts
    When the user removes it
    Then its credential, cached data and drafts are cleared

  # Legacy: apps/web/src/connection/storage.ts (corrupt catalog quarantined, empty catalog written back)
  @desktop
  Scenario: A damaged record of saved environments is set aside and the app starts with none
    Given the desktop app's record of saved environments is damaged
    When the app starts
    Then the app starts with no saved environments
    And the damaged record is kept apart so it can be inspected
    And the user can pair again without clearing anything by hand

  # Legacy: apps/web/src/connection/storage.ts (makeCatalogBackend desktop secure storage declines the write)
  @desktop
  Scenario: Pairing fails when the system's secure storage refuses to keep the credential
    Given the system's secure storage is unavailable to the app
    When the user pairs a new environment
    Then the user is told the environment could not be saved
    And the environment is not listed as saved
    And its credential is not written to disk in the clear

  # HAL-C2 Connect was removed; remote access is LAN pairing, Tailscale, SSH and clustering.
  @dropped @desktop @mobile
  Scenario: Signing out of HAL-C2 Connect keeps directly paired environments
    Given one relayed and one directly paired environment
    When the user signs out of HAL-C2 Connect
    Then the directly paired environment stays

  @shared
  Scenario Outline: A protocol mismatch blocks the connection with advice
    Given an environment whose MC speaks <protocol>
    When the client connects
    Then the connection is blocked
    And the client says <advice>

    Examples:
      | protocol                       | advice                                   |
      | a newer protocol than the client | update HAL-C2 on this device          |
      | an older protocol than the client | update HAL-C2 on that environment    |

  # Legacy: packages/client-runtime/src/connection/layer.ts (watchDiscoveredCompatibility)
  # HAL-C2 Connect was removed; remote access is LAN pairing, Tailscale, SSH and clustering.
  @dropped @desktop @mobile
  Scenario: A relayed environment on another protocol is marked blocked from the relay's health report
    Given HAL-C2 Connect lists an environment whose last health report shows a protocol the client does not speak
    When the client refreshes the relay's environments
    Then the environment is shown as blocked with the same advice
    And the client has not tried to connect to it

  # Upstream #13577: a relay's health report describes the server behind the relay, so it must
  # not disable a directly paired environment that shares its id. HAL-C2 Connect was removed.
  @dropped @desktop @mobile
  Scenario: A relay's protocol report does not disable a directly paired environment with the same id
    Given HAL-C2 Connect lists an environment with the same id as a directly paired one, on another protocol
    When the client refreshes the relay's environments
    Then the directly paired environment stays connected

  # A different app version does not block the connection; only a server behind the client
  # warns. settings/updates.feature holds updating the server from that warning and keeping
  # a dismissed notice dismissed for its version.
  @shared
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

  @shared
  Scenario: One connection serves every MC of a cluster
    Given a client connected to a cluster of three MCs
    Then the client keeps one connection for the cluster
    And streams from every MC arrive over it

  @shared
  Scenario: A cluster connection resumes each stream from where it stopped
    Given a client following threads on two cluster members
    When the cluster connection drops and returns
    Then each thread stream resumes from its last offset
    And the thread list asks only for the rows changed since

  @desktop
  Scenario: A thread on a computer that stays unavailable offers to disconnect it after 20 seconds
    Given the user is looking at a thread on the saved computer "studio"
    And "studio" has been offline or reconnecting for 20 seconds
    Then the notice about "studio" offers to disconnect it
    And before 20 seconds it offers only to reconnect

  @desktop
  Scenario: The 20 seconds start again for another computer
    Given the user is looking at a thread on "studio" that has been unavailable for 15 seconds
    When the user opens a thread on "laptop" that is also unavailable
    Then disconnecting "laptop" is offered only 20 seconds after it became unavailable

  @desktop
  Scenario: A computer that comes back inside the 20 seconds is never offered for disconnecting
    Given a thread on "studio" which has been unavailable for 10 seconds
    When "studio" connects again
    Then no offer to disconnect "studio" is shown
    And if it drops again the 20 seconds start over

  @desktop
  Scenario Outline: The computer the app runs on cannot be disconnected from a thread
    Given the user is looking at a thread on <computer>
    And <computer> has been unavailable for more than 20 seconds
    Then the notice does not offer to disconnect it

    Examples:
      | computer                                  |
      | the computer serving this client          |
      | a backend running on this same desktop    |

  @desktop
  Scenario: Disconnecting from a thread's notice hides that computer and goes home
    Given "studio" has been unavailable for 20 seconds
    When the user chooses to disconnect it from the thread's notice
    Then "studio" is switched off in connections
    And its threads are hidden
    And the user is taken to the home screen

  @desktop
  Scenario: A disconnect that fails says why
    Given "studio" has been unavailable for 20 seconds
    And switching "studio" off will fail
    When the user chooses to disconnect it from the thread's notice
    Then the user is told "Could not disconnect server" with the reason
    And the user stays on the thread

  @desktop
  Scenario: A reconnect that fails says why
    Given "studio" is offline
    And reconnecting will fail
    When the user chooses to reconnect it from the thread's notice
    Then the user is told "Could not reconnect environment" with the reason

  @desktop
  Scenario: A brief reconnect is not announced in the thread
    Given the user is looking at a thread on "studio"
    When "studio" drops and reconnects within two seconds
    Then the thread shows no notice about "studio"

  @desktop
  Scenario: A computer still reconnecting after two seconds is named in the thread
    Given the user is looking at a thread on "studio"
    When "studio" has been reconnecting for more than two seconds
    Then the thread says "studio is reconnecting"
    And reconnecting by hand is not offered while it is already trying

  # Upstream #20441: the elapsed grace of an earlier reconnect does not carry over.
  @backlog @desktop
  Scenario: Every reconnect gets its own two seconds before it is named in the thread
    Given the user is looking at a thread on "studio"
    And "studio" was named as reconnecting in the thread and then connected again
    When "studio" drops again and reconnects within two seconds
    Then the thread shows no notice about "studio"

  @desktop
  Scenario: An offline computer is named in the thread with a way to reconnect
    Given the user is looking at a thread on "studio"
    When "studio" stops trying to connect
    Then the thread says "studio is offline"
    And the user can ask it to reconnect

  @desktop
  Scenario: A computer restarting for an update shows the update, not a reconnect warning
    Given the user is looking at a thread on "studio"
    And an update of "studio" is running
    When "studio" drops and starts reconnecting
    Then the thread shows the update's progress
    And no notice says "studio" is reconnecting

  @desktop
  Scenario: A computer that stops connecting during an update can still be reconnected
    Given the user is looking at a thread on "studio"
    And an update of "studio" is running
    When "studio" stops trying to connect
    Then the thread says "studio is offline"
    And the user can ask it to reconnect

  # Upstream #13083: a computer that is only offline is not taken for one mid-update.
  @desktop
  Scenario: Reconnecting to a computer on another version is not taken for an update
    Given the user is looking at a thread on "studio"
    And "studio" runs a different version than this client and no update is known to be running
    When "studio" has been reconnecting for more than two seconds
    Then the thread says "studio is reconnecting"
    And no notice says "Finishing an update"

  @backlog @shared @priority-high
  Scenario: Reconnects back off with jitter
    Given the connection to an environment drops
    When the client retries
    Then waits grow with random jitter so clients do not retry in lockstep
    And an authorization or unsupported-version failure does not retry on the same session

  @backlog @shared @priority-high
  Scenario: A false offline report does not replace a healthy connection
    Given the connection is working
    When the device reports being offline then online
    Then the existing connection is kept

  @backlog @shared @priority-high
  Scenario: Failed subscriptions retry with growing delay
    Given a subscription keeps failing for an expected reason
    Then its retries double up to 30 seconds
    And the first value after a retry resets the delay

  @backlog @shared
  Scenario: A relay disconnect is a connection blip, not a thread error
    Given the Connect relay drops
    When the thread would show "<environment> disconnected." followed by a network hint
    Then it is treated as a connection problem and not shown as an error on the thread

  @backlog @shared
  Scenario: Closing a busy stream does not drop the connection
    Given the client is receiving a fast stream
    When the user switches away and the stream is closed
    Then the connection keeps reading replies and heartbeats and does not reconnect

  @backlog @shared @priority-high
  Scenario: A connection lost to silence says so
    Given the client's ping to an MC went unanswered
    When the connection is dropped
    Then the trace says the MC stopped responding, not that it disconnected
    And the interface still treats it as a transient drop
