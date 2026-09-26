# Sources:
#   docs/user/mobile-notifications.md (publishing must be on, T3 Connect required, 15-minute results)
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
  gets alerts and live activity through T3 Connect. Phones register with the relay, not with
  the node. The node publishes nothing yet.

  Background:
    Given a node linked to T3 Connect

  @backlog @node
  Scenario: Publishing is off until the user turns it on
    Given agent activity publishing is off
    When an agent finishes a turn
    Then the node publishes nothing to the relay

  @backlog @node
  Scenario Outline: The node publishes each phase of an agent's work
    Given agent activity publishing is on
    When an agent <event>
    Then the node publishes the thread's activity as "<phase>"
    And the update names the project, thread, model and a link to the thread

    Examples:
      | event                          | phase                |
      | starts a turn                  | starting             |
      | is working                     | running              |
      | asks for approval              | waiting_for_approval |
      | asks the user a question       | waiting_for_input    |
      | completes its turn             | completed            |
      | fails its turn                 | failed               |

  @backlog @node
  Scenario: Activity left behind by a restart is marked stale
    Given a published thread that was running
    When the node restarts without finishing it
    Then the node publishes it as stale

  @backlog @node
  Scenario: A deleted thread's activity is withdrawn
    Given a published thread
    When the thread is deleted
    Then the node publishes an empty state for it

  @backlog @node
  Scenario: Every update is signed by the node
    Given agent activity publishing is on
    When the node publishes an update
    Then the update carries the node's signed proof for that thread and state

  @backlog @node
  Scenario: The relay refuses a replayed update
    Given an update the relay already accepted
    When it is sent again
    Then the relay refuses it as a replay

  @backlog @node
  Scenario: Turning publishing off stops alerts
    Given agent activity publishing is on
    When the user turns it off
    Then later agent activity is not published

  @backlog @node
  Scenario: Removing the tunnel keeps publishing on
    Given agent activity publishing is on
    When the managed tunnel is removed
    Then publishing stays on

  @backlog @node
  Scenario: A directly paired environment cannot publish
    Given a node paired directly and not linked to T3 Connect
    Then the user cannot turn on agent activity publishing

  @backlog @node
  Scenario: A failed publish does not disturb the turn
    Given the relay cannot be reached
    When an agent completes its turn
    Then the turn completes as usual
    And the node tries the next update when it happens
