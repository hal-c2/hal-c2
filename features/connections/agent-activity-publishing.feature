# Sources:
#   docs/user/mobile-notifications.md (publishing must be on, HAL-C2 Connect required, 15-minute results)
#   packages/contracts/src/relay.ts (RelayAgentAwarenessPhase, RelayAgentActivityState,
#     RelayAgentActivityPublishRequest, RelayAgentActivityPublishProofInvalidReason,
#     RelayDeviceRegistrationRequest, RelayLiveActivityRegistrationRequest)
#   packages/contracts/src/environmentHttp.ts (/api/connect/preferences)
#   apps/server/src/cloud/http.ts (agent activity publisher)
#   apps/web/src/components/settings/ConnectionsSettings.tsx ("Publish agent activity to mobile clients",
#     "The managed tunnel was removed. Agent activity publishing stays on.")
#   Shared domain: mobile/notifications.feature holds the phone registering for alerts and showing them;
#   settings/connections.feature holds the desktop publishing switch.

Feature: Publishing agent activity
  A linked environment can sign and publish what its agents are doing so the user's phone
  gets alerts and live activity through HAL-C2 Connect. Phones register with the relay, not with
  the MC.

  Background:
    Given an MC linked to HAL-C2 Connect

  @mc
  Scenario: Publishing is off until the user turns it on
    Given agent activity publishing is off
    When an agent finishes a turn
    Then the MC publishes nothing to the relay

  @mc
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

  @mc
  # Neither server publishes a "stale" phase: the MC settles the cut-off turn as
  # interrupted when it starts, and an interrupted turn shows no activity.
  Scenario: Activity left behind by a restart is withdrawn
    Given a published thread that was running
    When the MC restarts without finishing it
    Then the MC withdraws the thread's activity

  @mc
  Scenario: A deleted thread's activity is withdrawn
    Given a published thread
    When the thread is deleted
    Then the MC publishes an empty state for it

  @mc
  Scenario: Every update is signed by the MC
    Given agent activity publishing is on
    When the MC publishes an update
    Then the update carries the MC's signed proof for that thread and state

  @mc
  Scenario: The relay refuses a replayed update
    Given an update the relay already accepted
    When it is sent again
    Then the relay refuses it as a replay

  @mc
  Scenario: Turning publishing off stops alerts
    Given agent activity publishing is on
    When the user turns it off
    Then later agent activity is not published

  @mc
  Scenario: Removing the tunnel keeps publishing on
    Given agent activity publishing is on
    When the managed tunnel is removed
    Then publishing stays on

  @mc
  Scenario: A directly paired environment cannot publish
    Given an MC paired directly and not linked to HAL-C2 Connect
    Then the user cannot turn on agent activity publishing

  @mc
  Scenario: A failed publish does not disturb the turn
    Given the relay cannot be reached
    When an agent completes its turn
    Then the turn completes as usual
    And the MC tries the next update when it happens
