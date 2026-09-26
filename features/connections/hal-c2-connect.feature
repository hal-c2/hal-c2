# Sources:
#   docs/user/remote-access.md (HAL-C2 Connect, Manage or revoke access, HAL-C2 Connect troubleshooting)
#   docs/internals/hal-c2-connect.md (trusted broker, DPoP-bound mint, link outlives a connector, OAuth traps)
#   docs/operations/connect-setup.md
#   docs/user/background-service.md (signing out of HAL-C2 Connect leaves the service alone)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (hal-c2-connect-linking, hal-c2-connect-relay-client)
#   apps/server-ex/test/hal_c2/node_parity_test.exs (cloud.getRelayClientStatus, cloud.installRelayClient)
#   packages/contracts/src/relayClient.ts (status, install stages, failure reasons)
#   packages/contracts/src/relay.ts
#   packages/contracts/src/environmentHttp.ts (/api/connect/*, /api/hal-c2-connect/*)
#   apps/server/src/cloud/http.ts, apps/server/src/cloud/ManagedEndpointRuntime.ts
#   apps/web/src/cloud/linkEnvironment.ts, apps/web/src/cloud/relayClientInstallDialog.ts
#   apps/web/src/components/cloud/RelayClientInstallDialog.tsx
#   apps/mobile/src/features/cloud/ (dpop.ts, linkEnvironment.ts, managedRelayTokenStore.ts,
#     HalC2ConnectProfilePage.tsx, ConnectOnboardingRouteScreen.tsx)
#   apps/tui/src/features.backlog.test.ts (environment-connections, relay client)
#   Shared domain: settings/connections.feature holds the desktop link switch;
#   mobile/pairing-and-environments.feature holds phone onboarding, relayed environments and deregistering.

Feature: HAL-C2 Connect
  HAL-C2 Connect links an environment to the user's cloud account so their other devices can
  reach it through a managed tunnel.

  Background:
    Given a running node
    And a user signed in to HAL-C2 Connect

  @node
  Scenario: Linking proves the node's identity and lists it for the account
    When the user links the node to their account
    Then the node proves its identity to the relay
    And the node joins the account's environment list

  @node
  Scenario: A linked node is reachable through its managed tunnel
    Given a linked node
    When a device signed in to the same account chooses it
    Then the device connects through the node's tunnel address

  @node
  Scenario: The relay brokers a credential the device redeems directly
    Given a linked node
    When a signed-in device asks the relay for access
    Then the node mints a one-time credential bound to that device's key
    And the device exchanges it with the node for a session
    And the relay never sees the session

  @node
  Scenario: A minted credential is useless without the device's key
    Given a credential minted for one device
    When another process presents it without that device's key
    Then the node refuses it

  @node
  Scenario: Health checks answer once per nonce
    Given a linked node
    When HAL-C2 Connect checks its health with a nonce
    Then the node answers with a response bound to that nonce
    When the same request is replayed
    Then the node refuses it

  @node
  Scenario: Relay requests that name another node or user are refused
    Given a linked node
    When a relay request arrives for another environment or another account
    Then the node refuses it

  @node
  Scenario: The tunnel exposes only the node's loopback origin
    Given a linked node
    When a request through the tunnel carries forwarded authority headers
    Then the node's link proof rejects it

  @node
  Scenario: Unlinking stops relay access
    Given a linked node
    When the user unlinks it
    Then the relay no longer reaches it
    And its link state reads unlinked

  @node
  Scenario: Unlinking keeps access if the teardown fails
    Given a linked node
    And the relay's database refuses the change
    # The relay's unlink (deregistering) revokes before teardown; the node's own unlink stops its tunnel first.
    When the user deregisters it from their account
    Then the link stays usable
    And the unlink can be retried

  @node
  Scenario: A link recorded while the node is stopped takes effect at startup
    Given the user linked the node while it was stopped
    When the node starts
    Then it brings up its tunnel

  @node
  Scenario: A normal shutdown releases the tunnel but keeps the address
    Given a node linked from the command line
    When the node shuts down
    Then its tunnel is released
    And the account shows it offline rather than unauthorized
    And the next start reuses its address

  @node
  Scenario: A hot upgrade keeps the tunnel
    Given a linked node
    When the node upgrades itself
    Then its tunnel stays up throughout

  @node
  Scenario: Deregistering frees an offline node's place
    Given a linked node that is offline
    When the user deregisters it from their account
    Then its cloud access is revoked
    And its place counts no longer toward the account's limit

  @node
  Scenario: An operator links the node from the command line
    When an operator runs the connect command on the host
    Then it asks the operator to sign in
    And offers to install the background service

  @node
  Scenario: Signing in over SSH uses a device code
    Given an operator on the host over SSH
    When the operator runs the connect command
    Then it prints a browser link and a short code
    And continues once the code is approved on another device

  @node
  Scenario: Saving a sign-in alone does not make the node reachable
    Given an operator signed in without starting the node
    Then no device can reach the node until it runs

  @node
  Scenario: The operator inspects the saved link
    When the operator asks for the connect status
    Then it prints the saved authorization and link settings
    And does not test reachability

  @node
  Scenario: Unlinking from the command line keeps the sign-in
    Given a linked node
    When the operator unlinks from the command line
    Then the node stops being exposed
    And the operator stays signed in

  @node
  Scenario: Logging out clears the sign-in and the link
    Given a linked node
    When the operator logs out from the command line
    Then the stored cloud credential is removed
    And exposure is disabled
    And the background service stays installed

  @backlog @desktop @mobile
  Scenario: Signing out of HAL-C2 Connect in the app leaves the background service running
    Given the host runs HAL-C2 as a background service
    When the user signs out of HAL-C2 Connect
    Then the background service keeps running and stays installed

  @node
  Scenario: Credentials renew without disconnecting
    Given a device connected through HAL-C2 Connect
    When its access credential expires
    Then it is renewed without closing the connection
    And a renewal that fails affects only that request

  @node
  Scenario Outline: A failure at startup names its recovery
    Given the relay answers the node with <failure>
    When the node starts
    Then it reports <recovery>

    Examples:
      | failure                                   | recovery                                                    |
      | the environment link limit                | deregister an unused environment, then restart              |
      | an invalid or revoked bearer              | sign in again, then restart                                 |
      | an expired or invalid link proof          | check the host's clock and update                           |
      | a 403 without a recognised error          | check relay access, proxies and firewall rules              |

  @node
  Scenario: Temporary relay failures are retried at startup
    Given the relay answers 408, 429 or a server error
    When the node starts
    Then it keeps retrying for up to ten minutes

  @node
  Scenario Outline: The node reports its relay client
    Given the relay client is <state>
    When a client asks for the relay client status
    Then the relay client status is "<status>"

    Examples:
      | state                                    | status      |
      | installed by the node                    | available   |
      | found on the PATH                        | available   |
      | given by an override path                | available   |
      | not installed                            | missing     |
      | not built for this platform              | unsupported |

  @node
  Scenario: Installing the relay client streams its stages
    Given the relay client is missing
    When a client installs it
    Then the node reports checking, downloading, verifying, installing, validating and activating
    And finishes with the client available

  @node
  Scenario: A second install waits for the first
    Given a relay client install in progress
    When another client installs it
    Then the second install waits for the lock

  @node
  Scenario Outline: A relay client install that fails says why
    Given <situation>
    When a client installs the relay client
    Then the install fails with "<reason>"

    Examples:
      | situation                                  | reason               |
      | the download fails                         | download_failed      |
      | the download's checksum does not match     | invalid_checksum     |
      | another install holds the lock too long    | install_locked       |
      | the override path does not exist           | override_missing     |
      | the platform has no relay client           | unsupported_platform |
      | the installed client does not run          | validation_failed    |
      | the install folder cannot be written       | write_failed         |

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: The terminal client connects a relayed environment
    Given an environment the account can reach through HAL-C2 Connect
    When the user connects it from the terminal client
    Then the terminal client checks for the relay client
    And guides the user through installing it when it is missing
