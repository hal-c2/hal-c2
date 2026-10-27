# Sources:
#   https://github.com/pingdotgg/t3code/pull/13340 (restart replay of old alerts; relay dropped below)
#   docs/user/mobile-notifications.md (publishing must be on, HAL-C2 Connect required, 15-minute results)
#   packages/contracts/src/relay.ts (RelayAgentAwarenessPhase, RelayAgentActivityState,
#     RelayAgentActivityPublishRequest, RelayAgentActivityPublishProofInvalidReason,
#     RelayDeviceRegistrationRequest, RelayLiveActivityRegistrationRequest)
#   packages/contracts/src/environmentHttp.ts (/api/connect/preferences)
#   apps/server/src/cloud/http.ts (agent activity publisher)
#   apps/server/src/relay/AgentAwarenessRelay.ts (which events publish, coalescing, confirmation, retries)
#   apps/web/src/components/settings/ConnectionsSettings.tsx ("Publish agent activity to mobile clients",
#     "The managed tunnel was removed. Agent activity publishing stays on.")
#   Shared domain: mobile/notifications.feature holds the phone registering for alerts and showing them;
#   settings/connections.feature holds the desktop publishing switch.

# HAL-C2 Connect was removed: the MC is reached over the LAN or a tailnet, and
# machines share one sidebar through the cluster (connections/cluster.feature).
# The scenarios stay as the record of what it did.
Feature: Publishing agent activity
  A linked environment can sign and publish what its agents are doing so the user's phone
  gets alerts and live activity through HAL-C2 Connect. Phones register with the relay, not with
  the MC.

  Background:
    Given an MC linked to HAL-C2 Connect

  @dropped @mc
  Scenario: Publishing is off until the user turns it on
    Given agent activity publishing is off
    When an agent finishes a turn
    Then the MC publishes nothing to the relay

  @dropped @mc
  Scenario Outline: The MC publishes each phase of an agent's work
    Given agent activity publishing is on
    When an agent <event>
    Then the MC publishes the thread's activity as "<phase>"
    And the update names the project, thread, model and a link to the thread

    Examples:
      | event                          | phase                |
      | starts a turn                  | starting             |
      | is working                     | running              |
      | asks for approval              | waiting_for_approval |
      | asks the user a question       | waiting_for_input    |
      | completes its turn             | completed            |
      | fails its turn                 | failed               |

  @dropped @mc
  # Neither server publishes a "stale" phase: the MC settles the cut-off turn as
  # interrupted when it starts, and an interrupted turn shows no activity.
  Scenario: Activity left behind by a restart is withdrawn
    Given a published thread that was running
    When the MC restarts without finishing it
    Then the MC withdraws the thread's activity

  @dropped @mc
  Scenario: A deleted thread's activity is withdrawn
    Given a published thread
    When the thread is deleted
    Then the MC publishes an empty state for it

  @dropped @mc
  Scenario: Every update is signed by the MC
    Given agent activity publishing is on
    When the MC publishes an update
    Then the update carries the MC's signed proof for that thread and state

  @dropped @mc
  Scenario: The relay refuses a replayed update
    Given an update the relay already accepted
    When it is sent again
    Then the relay refuses it as a replay

  @dropped @mc
  Scenario: Turning publishing off stops alerts
    Given agent activity publishing is on
    When the user turns it off
    Then later agent activity is not published

  @dropped @mc
  Scenario: Removing the tunnel keeps publishing on
    Given agent activity publishing is on
    When the managed tunnel is removed
    Then publishing stays on

  @dropped @mc
  Scenario: A directly paired environment cannot publish
    Given an MC paired directly and not linked to HAL-C2 Connect
    Then the user cannot turn on agent activity publishing

  @dropped @mc
  Scenario: A failed publish does not disturb the turn
    Given the relay cannot be reached
    When an agent completes its turn
    Then the turn completes as usual
    And the MC tries the next update when it happens

  @dropped @mc
  Scenario Outline: Only changes to what the agent is doing are published
    Given a published thread
    When <event>
    Then the MC <outcome>

    Examples:
      | event                                          | outcome                      |
      | the agent writes more of its reply             | publishes nothing            |
      | a tool call progresses                         | publishes nothing            |
      | the user opens or pins the thread              | publishes nothing            |
      | a run starts, changes or waits on the user     | publishes the new state      |
      | the thread's title or model changes            | publishes the new state      |
      | the thread is archived, restored or deleted    | publishes the new state      |

  @dropped @mc
  Scenario: Threads brought in from an older import are not announced as new activity
    Given publishing is on
    When threads are imported from another install
    Then the MC publishes nothing for them

  # Upstream (#13340) stopped a restarted desktop server from replaying old "Done" alerts.
  # The alerts went through HAL-C2 Connect, which was removed, so there is nothing to replay.
  @dropped @mc
  Scenario: Restarting the MC does not alert about work that finished before it
    Given a thread finished its turn before the MC restarted
    When the MC restarts
    Then the MC publishes no alert for that finished turn

  @dropped @mc
  Scenario: A burst of changes to one thread is published once
    Given a published thread
    When many changes to it arrive while a publish is in flight
    Then the MC publishes the latest state once the publish finishes
    And it does not publish an unchanged state twice

  @dropped @mc
  Scenario: A thread's first state is not announced as completed until it holds
    Given a new thread whose session briefly looks completed before its first turn
    When the MC would publish that first state
    Then it waits a few seconds and publishes only if the thread is still completed

  @dropped @mc
  Scenario: A thread's activity is not withdrawn on a momentary gap
    Given a published thread that is running
    When its projection is momentarily empty while the MC writes
    Then the MC waits a few seconds before withdrawing it
    And it does not withdraw it if the thread is running again

  @dropped @mc
  Scenario: A failed publish is retried with growing delays and then given up
    Given the relay cannot be reached
    When an agent changes state
    Then the MC retries after one, two, four, eight and sixteen seconds
    And it stops retrying after that until a newer update arrives

  @dropped @mc
  Scenario: A newer update cancels a retry for an older one
    Given a publish that failed and is waiting to retry
    When a newer update for the thread publishes successfully
    Then the pending retry is cancelled

  @dropped @mc
  Scenario: Unchanged activity is published again after relinking
    Given publishing was on and the MC published a thread's state
    When the user unlinks and links the MC again
    Then the MC publishes the thread's current state with the new credentials

  @dropped @mc
  Scenario: Turning publishing off cancels updates that are waiting
    Given an update is waiting to be published or retried
    When the user turns publishing off or unlinks the MC
    Then nothing more is sent for it
    And turning publishing back on publishes the current state

  @dropped @mc
  Scenario: A long activity description is shortened
    Given a thread whose current activity has a very long description
    When the MC publishes it
    Then the description is limited to 160 characters
