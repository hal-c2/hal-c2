# Sources:
#   docs/user/remote-access.md (HAL-C2 Connect, Manage or revoke access, HAL-C2 Connect troubleshooting)
#   docs/internals/hal-c2-connect.md (trusted broker, DPoP-bound mint, link outlives a connector, OAuth traps)
#   docs/operations/connect-setup.md
#   docs/user/background-service.md (signing out of HAL-C2 Connect leaves the service alone)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (hal-c2-connect-linking, hal-c2-connect-relay-client)
#   apps/server-ex/test/hal_c2/mc_parity_test.exs (cloud.getRelayClientStatus, cloud.installRelayClient)
#   packages/contracts/src/relayClient.ts (status, install stages, failure reasons)
#   packages/contracts/src/relay.ts
#   packages/contracts/src/environmentHttp.ts (/api/connect/*, /api/hal-c2-connect/*)
#   apps/server/src/cloud/http.ts, apps/server/src/cloud/ManagedEndpointRuntime.ts
#   apps/server/src/cloud/CliTokenManager.ts (browser and device-code sign-in, renewal)
#   apps/server/src/cloud/CliState.ts, apps/server/src/cloud/relayResponse.ts (relay failures, Ray ID)
#   apps/server/src/cloud/publicConfig.ts (secure relay origin, sign-in loopback port)
#   apps/server/src/binCli.ts (the connect command in a build without public configuration)
#   apps/server/src/cloud/environmentKeys.ts (the MC's identity key pair is created once and reused)
#   apps/web/src/cloud/linkEnvironment.ts, apps/web/src/cloud/relayClientInstallDialog.ts
#   apps/web/src/components/cloud/RelayClientInstallDialog.tsx
#   apps/web/src/cloud/useCloudLinkController.ts, primaryCloudLinkState.ts, connectOnboarding.ts, managedAuth.tsx
#   apps/web/src/components/cloud/ConnectOnboardingDialog.tsx, CloudEnvironmentConnectList.tsx,
#     cloudEnvironmentConnectionPresentation.ts, ConnectCliAuthSurface.tsx
#   apps/web/src/cloud/connectCliAuth.ts (the hosted /connect page)
#   apps/web/src/components/clerk/HalC2ConnectUserProfilePage.tsx, MobileClientsUserProfilePage.tsx,
#     HalC2ConnectSidebarSignIn.tsx (account pages, sidebar sign-in)
#   apps/mobile/src/features/cloud/ (dpop.ts, linkEnvironment.ts, managedRelayTokenStore.ts,
#     HalC2ConnectProfilePage.tsx, ConnectOnboardingRouteScreen.tsx)
#   apps/tui/src/features.backlog.test.ts (environment-connections, relay client)
#   packages/client-runtime/src/relay/errorPresentation.ts, relay/managedRelay.ts, relay/discovery.ts
#     (relay refusals in plain words, DPoP clock hint, 10 s request timeout, status validation)
#   packages/client-runtime/src/errors/network.ts (the filtering-network hint)
#   Shared domain: settings/connections.feature holds the desktop link switch;
#   mobile/pairing-and-environments.feature holds phone onboarding, relayed environments and deregistering.

Feature: HAL-C2 Connect
  HAL-C2 Connect links an environment to the user's cloud account so their other devices can
  reach it through a managed tunnel.

  Background:
    Given a running MC
    And a user signed in to HAL-C2 Connect

  @mc
  Scenario: Linking proves the MC's identity and lists it for the account
    When the user links the MC to their account
    Then the MC proves its identity to the relay
    And the MC joins the account's environment list

  @backlog @mc
  Scenario: The MC keeps one identity across restarts
    Given a linked MC
    When the MC restarts
    Then it proves the same identity to the relay
    And it is still the same entry in the account's environment list

  @backlog @mc
  Scenario: Two starts racing to create the MC's identity end with one
    Given an MC that has never been linked
    When two processes create its identity at the same moment
    Then both use the identity that was stored first

  @mc
  Scenario: A linked MC is reachable through its managed tunnel
    Given a linked MC
    When a device signed in to the same account chooses it
    Then the device connects through the MC's tunnel address

  @mc
  Scenario: The relay brokers a credential the device redeems directly
    Given a linked MC
    When a signed-in device asks the relay for access
    Then the MC mints a one-time credential bound to that device's key
    And the device exchanges it with the MC for a session
    And the relay never sees the session

  @mc
  Scenario: A minted credential is useless without the device's key
    Given a credential minted for one device
    When another process presents it without that device's key
    Then the MC refuses it

  @mc
  Scenario: Health checks answer once per nonce
    Given a linked MC
    When HAL-C2 Connect checks its health with a nonce
    Then the MC answers with a response bound to that nonce
    When the same request is replayed
    Then the MC refuses it

  @mc
  Scenario: Relay requests that name another MC or user are refused
    Given a linked MC
    When a relay request arrives for another environment or another account
    Then the MC refuses it

  @mc
  Scenario: The tunnel exposes only the MC's loopback origin
    Given a linked MC
    When a request through the tunnel carries forwarded authority headers
    Then the MC's link proof rejects it

  @mc
  Scenario: Unlinking stops relay access
    Given a linked MC
    When the user unlinks it
    Then the relay no longer reaches it
    And its link state reads unlinked

  @mc
  Scenario: Unlinking keeps access if the teardown fails
    Given a linked MC
    And the relay's database refuses the change
    # The relay's unlink (deregistering) revokes before teardown; the MC's own unlink stops its tunnel first.
    When the user deregisters it from their account
    Then the link stays usable
    And the unlink can be retried

  @mc
  Scenario: A link recorded while the MC is stopped takes effect at startup
    Given the user linked the MC while it was stopped
    When the MC starts
    Then it brings up its tunnel

  @mc
  Scenario: A normal shutdown releases the tunnel but keeps the address
    Given an MC linked from the command line
    When the MC shuts down
    Then its tunnel is released
    And the account shows it offline rather than unauthorized
    And the next start reuses its address

  @mc
  Scenario: A hot upgrade keeps the tunnel
    Given a linked MC
    When the MC upgrades itself
    Then its tunnel stays up throughout

  @backlog @mc
  Scenario: A tunnel connector that exits is started again
    Given a linked MC with its tunnel up
    When the tunnel connector process exits
    Then the MC starts it again without the user doing anything

  @backlog @mc
  Scenario: A connector that keeps crashing is restarted with growing delays
    Given a linked MC whose tunnel connector exits right after it starts
    Then the MC waits one second before the first restart
    And each further restart waits twice as long, up to one minute
    And the delay starts over once the connector has run for thirty seconds
    And changing the tunnel's configuration starts over at one second

  @backlog @mc
  Scenario: The connector's token never reaches the logs
    Given a linked MC with its tunnel up
    When the MC logs the connector's command line and output
    Then the connector's token is replaced by a placeholder

  @backlog @mc
  Scenario Outline: A tunnel that cannot start reports why
    Given a linked MC
    When <problem>
    Then the tunnel's status is failed with a reason the user can read
    And the MC keeps serving local clients

    Examples:
      | problem                                         |
      | the relay client is not installed               |
      | the relay client is not built for this platform |
      | the connector process cannot be started         |

  # Likely already implemented: apps/server-ex/lib/hal_c2/connect.ex
  @backlog @mc
  Scenario: A link can publish alerts without opening a tunnel
    Given the user linked the MC for notifications and live activities only
    When the MC runs
    Then the account lists the MC for alerts and live activities
    And no tunnel is brought up

  @backlog @mc
  Scenario: A link installed from an app keeps its tunnel across an MC restart
    Given the MC was linked from an app rather than from the command line
    When the MC shuts down
    Then its tunnel is not released
    And the stored connector configuration is kept

  @backlog @mc
  Scenario: A tunnel that cannot be released keeps its stored connection
    Given an MC linked from the command line
    When the MC shuts down and releasing the tunnel fails
    Then the stored connector configuration is kept
    And the next start can use it

  @mc
  Scenario: Deregistering frees an offline MC's place
    Given a linked MC that is offline
    When the user deregisters it from their account
    Then its cloud access is revoked
    And its place counts no longer toward the account's limit

  @mc
  Scenario: An operator links the MC from the command line
    When an operator runs the connect command on the host
    Then it asks the operator to sign in
    And offers to install the background service

  @mc
  Scenario: Signing in over SSH uses a device code
    Given an operator on the host over SSH
    When the operator runs the connect command
    Then it prints a browser link and a short code
    And continues once the code is approved on another device

  @backlog @mc
  Scenario: The operator chooses between the browser and a device code while signing in
    When an operator runs the connect command on a machine with a browser
    Then pressing Enter opens the browser to sign in
    And pressing H switches to a device code instead
    And if no browser can be opened it says so and falls back to the device code

  @backlog @mc
  Scenario: A browser sign-in that nobody completes gives up after ten minutes
    Given an operator started signing in with the browser
    When ten minutes pass without the browser returning
    Then the connect command stops waiting and says the sign-in timed out

  @backlog @mc
  Scenario: A build without HAL-C2 Connect's public settings says so instead of failing obscurely
    Given a build of the MC that carries no HAL-C2 Connect public configuration
    When an operator runs the connect command
    Then the command says HAL-C2 Connect is unavailable in this build because the configuration is missing
    And the command is not offered in the command's help

  @backlog @mc
  Scenario: A browser sign-in that returns with the wrong state is refused
    Given an operator started signing in with the browser
    When the browser returns to the MC with a state that the MC did not issue
    Then the MC refuses it and does not save a sign-in

  @backlog @mc
  Scenario Outline: A device code that is not approved ends the sign-in clearly
    Given an operator is waiting on a device code
    When <event>
    Then the connect command stops and says <message>

    Examples:
      | event                                 | message                              |
      | the user denies the code on their device | the sign-in was denied            |
      | the code expires before it is approved   | the sign-in timed out             |

  @backlog @mc
  Scenario: Waiting for a device code slows down when asked and rides out network blips
    Given an operator is waiting on a device code
    When the sign-in service asks the MC to slow down
    Then the MC waits five seconds longer between checks
    And a failed or server-error check also waits longer before the next one
    And a code that is still pending keeps being checked

  @mc
  Scenario: Saving a sign-in alone does not make the MC reachable
    Given an operator signed in without starting the MC
    Then no device can reach the MC until it runs

  @backlog @mc
  Scenario: A saved sign-in is renewed shortly before it expires
    Given an operator signed in earlier
    When the saved sign-in is within five minutes of expiring and the operator runs the connect command
    Then the sign-in is renewed without asking the operator to sign in again

  @backlog @mc
  Scenario: A saved sign-in that cannot be renewed falls back to a fresh sign-in
    Given an operator signed in earlier
    And the saved sign-in has expired and cannot be renewed
    When the operator runs the connect command
    Then it asks the operator to sign in again

  @mc
  Scenario: The operator inspects the saved link
    When the operator asks for the connect status
    Then it prints the saved authorization and link settings
    And does not test reachability

  @mc
  Scenario: Unlinking from the command line keeps the sign-in
    Given a linked MC
    When the operator unlinks from the command line
    Then the MC stops being exposed
    And the operator stays signed in

  @mc
  Scenario: Logging out clears the sign-in and the link
    Given a linked MC
    When the operator logs out from the command line
    Then the stored cloud credential is removed
    And exposure is disabled
    And the background service stays installed

  @backlog @desktop @mobile
  Scenario: Signing out of HAL-C2 Connect in the app leaves the background service running
    Given the host runs HAL-C2 as a background service
    When the user signs out of HAL-C2 Connect
    Then the background service keeps running and stays installed

  @mc
  Scenario: Credentials renew without disconnecting
    Given a device connected through HAL-C2 Connect
    When its access credential expires
    Then it is renewed without closing the connection
    And a renewal that fails affects only that request

  @mc
  Scenario Outline: A failure at startup names its recovery
    Given the relay answers the MC with <failure>
    When the MC starts
    Then it reports <recovery>

    Examples:
      | failure                                   | recovery                                                    |
      | the environment link limit                | deregister an unused environment, then restart              |
      | an invalid or revoked bearer              | sign in again, then restart                                 |
      | an expired or invalid link proof          | check the host's clock and update                           |
      | a 403 without a recognised error          | check relay access, proxies and firewall rules              |

  @mc
  Scenario: Temporary relay failures are retried at startup
    Given the relay answers 408, 429 or a server error
    When the MC starts
    Then it keeps retrying for up to ten minutes

  @backlog @mc
  Scenario: A relay rejection that retrying cannot fix is not retried
    Given the relay rejects the MC's link with a 4xx answer other than 408 or 429
    When the MC starts
    Then it reports the rejection straight away
    And it does not keep retrying

  @backlog @mc
  Scenario: A relay failure names the request so it can be reported
    Given the relay rejects the MC's link behind Cloudflare
    When the MC reports the failure
    Then the message includes the Cloudflare Ray ID of the request
    And a failure the relay's own answer cannot explain tells the user to include the trace ID when reporting it

  @backlog @mc
  Scenario Outline: A relay address that is not a secure origin is refused
    Given the operator configures the relay address as <address>
    When the MC reads its HAL-C2 Connect configuration
    Then it refuses it saying the relay must be a secure absolute HTTPS origin

    Examples:
      | address                          |
      | a plain http address             |
      | an https address with a path     |

  @backlog @mc
  Scenario: A browser sign-in returns to a fixed local port
    When an operator signs in with the browser from the command line
    Then the browser returns to the MC on loopback at port 34338

  @mc
  Scenario Outline: The MC reports its relay client
    Given the relay client is <state>
    When a client asks for the relay client status
    Then the relay client status is "<status>"

    Examples:
      | state                       | status      |
      | installed by the MC         | available   |
      | found on the PATH           | available   |
      | given by an override path   | available   |
      | not installed               | missing     |
      | not built for this platform | unsupported |

  @mc
  Scenario: Installing the relay client streams its stages
    Given the relay client is missing
    When a client installs it
    Then the MC reports checking, downloading, verifying, installing, validating and activating
    And finishes with the client available

  @mc
  Scenario: A second install waits for the first
    Given a relay client install in progress
    When another client installs it
    Then the second install waits for the lock

  @mc
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

  # The desktop app's own HAL-C2 Connect controls: the link, the setup after signing in,
  # the list of the account's environments, and the account pages.
  @backlog @desktop
  Scenario Outline: The app links this machine in the mode the user chose
    Given this machine is not linked to HAL-C2 Connect
    When the user turns on <choice>
    Then this machine is linked <how>

    Examples:
      | choice                              | how                                         |
      | HAL-C2 Connect                      | with a managed tunnel                       |
      | publishing agent activity only      | to publish agent activity without a tunnel  |

  @backlog @desktop
  Scenario: Turning HAL-C2 Connect off works without a fresh sign-in token
    Given this machine is linked to HAL-C2 Connect
    And the app cannot read the account's sign-in token
    When the user turns off HAL-C2 Connect and agent activity publishing
    Then this machine is unlinked

  @backlog @desktop
  Scenario: A HAL-C2 Connect change that fails is reported with its trace ID
    Given the MC refuses to change the HAL-C2 Connect link
    When the user turns on HAL-C2 Connect
    Then the user is told "Could not update HAL-C2 Connect" with the reason
    And the user can copy the trace ID
    And the HAL-C2 Connect choices show what the MC actually holds

  @backlog @desktop
  Scenario: An older MC that reports only that it is linked is treated as tunnelled
    Given the MC reports that it is linked but not whether its tunnel is active
    When the user opens Connections settings
    Then HAL-C2 Connect shows as on

  # Legacy: apps/web/src/cloud/useCloudLinkController.ts (reconcileCloudState)
  @backlog @desktop
  Scenario: Turning HAL-C2 Connect on without a sign-in says to sign in first
    Given the app has no HAL-C2 Connect sign-in token
    When the user turns on HAL-C2 Connect
    Then the user is told "Sign in to HAL-C2 Connect before enabling this."
    And this machine is not linked

  # Legacy: apps/web/src/cloud/useCloudLinkController.ts (reconcileCloudState, no primary target)
  @backlog @desktop
  Scenario: Turning HAL-C2 Connect on before this machine's MC is ready says so
    Given the app has not yet reached this machine's MC
    When the user turns on HAL-C2 Connect
    Then the user is told "Local environment is not ready yet."

  # Legacy: apps/web/src/cloud/linkEnvironment.ts (ensureLinkedEnvironmentMatches)
  @backlog @desktop
  Scenario Outline: Linking is refused when the relay answers for something else
    Given the relay answers the link request with credentials for <wrong>
    When the user turns on HAL-C2 Connect
    Then the link is refused with "<message>"
    And the MC is not given the relay's credentials

    Examples:
      | wrong                       | message                                                       |
      | a different environment     | Relay returned credentials for a different environment.       |
      | a different tunnel provider | Relay returned credentials for a different endpoint provider. |

  # Legacy: apps/web/src/cloud/linkEnvironment.ts (ensureRelayClientAvailable)
  @backlog @desktop
  Scenario: A platform the relay client cannot be installed on says so
    Given the relay client is missing
    And the platform is one the app cannot install it on automatically
    When the user turns on HAL-C2 Connect
    Then the link is refused with "HAL-C2 cannot install the relay client automatically on" followed by the platform and architecture
    And the user is not asked to install anything

  # Legacy: apps/web/src/cloud/linkEnvironment.ts (ensureRelayClientAvailable)
  @backlog @desktop
  Scenario Outline: An install that does not leave a relay client stops the link with a reason
    Given the relay client is missing
    And the user agreed to install it
    And <situation>
    When the user turns on HAL-C2 Connect
    Then the link is refused with "<message>"

    Examples:
      | situation                                               | message                                                    |
      | the install ends without saying whether it finished     | The relay client install completed without a final status. |
      | the install finishes but the client is still not there  | The relay client is still unavailable after installation.  |

  # Legacy: apps/web/src/cloud/linkEnvironment.ts (managed tunnel only checks the relay client)
  @backlog @desktop
  Scenario: Publishing agent activity only does not need the relay client
    Given the relay client is missing
    When the user turns on publishing agent activity only
    Then this machine is linked without asking to install the relay client

  # Legacy: apps/web/src/cloud/linkEnvironment.ts (unlinkPrimaryEnvironmentFromCloud)
  @backlog @desktop
  Scenario: Turning HAL-C2 Connect off still works when the relay cannot be told
    Given this machine is linked to HAL-C2 Connect
    And the relay cannot be reached
    When the user turns off HAL-C2 Connect and agent activity publishing
    Then this machine is unlinked
    And the user is not shown an error
    And the account's registration is revoked when the user next removes it

  @backlog @desktop
  Scenario: Signing in offers to set up HAL-C2 Connect
    Given the user is signed out of HAL-C2 Connect
    When the user signs in
    Then the user is offered to set up HAL-C2 Connect
    And the offer first asks whether to publish this machine and its agent activity
    And then lists the account's other environments

  @backlog @desktop
  Scenario: Restoring a saved sign-in does not offer the setup again
    Given the user signed in to HAL-C2 Connect earlier
    When the app starts with that sign-in restored
    Then the user is not offered the HAL-C2 Connect setup

  @backlog @desktop
  Scenario: Setup publishes this machine with both choices on by default
    Given the HAL-C2 Connect setup is showing and this machine is not linked
    When the user continues without changing anything
    Then this machine is linked with a managed tunnel
    And its agent activity is published
    And the user is told HAL-C2 Connect is enabled

  @backlog @desktop
  Scenario: Setup shows the link this machine already has
    Given this machine is already linked to the signed-in account with agent activity off
    When the HAL-C2 Connect setup opens
    Then the choices show the existing link rather than the defaults

  @backlog @desktop
  Scenario: Setup with both choices off changes nothing
    Given this machine is linked to HAL-C2 Connect
    When the user turns both setup choices off and continues
    Then the link is left as it was
    And the setup moves on to the account's environments

  @backlog @desktop
  Scenario: Setup skips the publish choice for a session that cannot manage the link
    Given the user's session may not manage this machine's HAL-C2 Connect link
    When the HAL-C2 Connect setup opens
    Then it goes straight to the account's other environments

  @backlog @desktop
  Scenario: Setup can be declined for good per account
    Given the HAL-C2 Connect setup is showing
    When the user asks not to see it again and finishes
    Then the setup does not open on later sign-ins of that account
    But it still opens for another account

  @backlog @desktop
  Scenario: Setup closes when the user signs out of it
    Given the HAL-C2 Connect setup is showing
    When the user signs out of HAL-C2 Connect
    Then the setup closes

  @backlog @desktop
  Scenario: A failed link during setup stays visible
    Given the HAL-C2 Connect setup is linking this machine
    When linking fails
    Then the setup stays open with the reason
    And the user can try again or skip it

  @backlog @desktop
  Scenario: Signing in to HAL-C2 Connect is offered from the sidebar
    Given the user is signed out of HAL-C2 Connect
    When the user looks at the sidebar
    Then "Sign in to HAL-C2 Connect" is offered

  # Legacy: apps/web/src/components/clerk/ElectronManagedAuthShell.tsx (passkeys), apps/desktop/src/app/DesktopClerk.ts
  # Uncertain: the Qt app may sign in only through the browser, where the browser supplies passkeys.
  @backlog @desktop
  Scenario: The user signs in to HAL-C2 Connect with a passkey
    Given the user has a passkey for their HAL-C2 Connect account
    When the user signs in to HAL-C2 Connect from the desktop app
    Then the user can choose to sign in with the passkey
    And the account is signed in without a password

  @backlog @desktop
  Scenario: A build without HAL-C2 Connect's public settings hides its controls
    Given the build has no HAL-C2 Connect public settings
    When the user looks at the sidebar and Connections settings
    Then no HAL-C2 Connect sign-in is offered

  @backlog @desktop
  Scenario: Switching HAL-C2 Connect accounts removes the previous account's environments
    Given the app uses "Office Mac" through the account "alice"
    When the user signs out and signs in as "bob"
    Then "Office Mac" is no longer listed on this device
    And the environments of "bob" are listed instead

  @backlog @desktop
  Scenario: The account's environments are listed with their relay status
    Given the account has "Office Mac" online, "Old Laptop" offline and "Studio" that the relay cannot answer for
    When the user opens the list of HAL-C2 Connect environments
    Then "Office Mac" is shown as available to add
    And "Old Laptop" is shown as offline
    And "Studio" is shown as unavailable

  @backlog @desktop
  Scenario: This machine and environments already added are left out of the list
    Given the account has this machine, "Office Mac" already added and "Old Laptop"
    When the user opens the list of HAL-C2 Connect environments outside the setup
    Then only "Old Laptop" is listed

  @backlog @desktop
  Scenario: The setup shows how each added environment is connected
    Given "Office Mac" was added through HAL-C2 Connect
    When the HAL-C2 Connect setup lists the account's environments
    Then "Office Mac" shows its live connection state
    And it cannot be added again

  @backlog @desktop
  Scenario: A list that cannot be loaded is not reported as empty
    Given the app cannot reach HAL-C2 Connect
    When the user opens the list of HAL-C2 Connect environments
    Then the user is told the environments could not be loaded
    And is told "You appear to be offline." when the device has no network

  @backlog @desktop
  Scenario: An empty list explains where environments come from
    Given the account has no other environments
    When the HAL-C2 Connect setup lists the account's environments
    Then the user is told no other environments are published to the account yet
    And that one published from another device will show up there

  @backlog @desktop
  Scenario: A machine that appears later is listed without reopening the list
    Given the account's list of environments is empty
    When another device publishes an environment
    Then it appears in the list without the user asking again

  @backlog @desktop
  Scenario: Adding an environment from the list connects through HAL-C2 Connect
    Given "Office Mac" is listed
    When the user adds "Office Mac"
    Then the user is told "Connecting to Office Mac through HAL-C2 Connect."
    And "Office Mac" is saved on this device

  @backlog @desktop
  Scenario: An environment that cannot be added is reported with its trace ID
    Given "Office Mac" is listed
    And connecting to it fails
    When the user adds "Office Mac"
    Then the user is told "Could not connect environment" with the reason
    And the user can copy the trace ID

  # Legacy: packages/client-runtime/src/relay/errorPresentation.ts (relayProtectedErrorMessage)
  @backlog @desktop @mobile
  Scenario Outline: A refusal from HAL-C2 Connect is explained in plain words
    Given HAL-C2 Connect refuses a request because <cause>
    When the user connects to an environment through HAL-C2 Connect
    Then the user is told "<message>"

    Examples:
      | cause                                              | message                                                                                                         |
      | the HAL-C2 Connect session token is missing or bad | Relay rejected the cloud session token.                                                                         |
      | the request is not authorized                      | Relay rejected the authenticated request.                                                                       |
      | the environment has no active link                 | Relay has no active link for this environment. The environment server may not have re-established its link yet. |
      | the environment's endpoint does not answer         | Relay timed out while contacting the environment endpoint.                                                      |
      | the link proof has expired                         | Relay rejected an expired environment link proof.                                                               |

  # Legacy: packages/client-runtime/src/relay/errorPresentation.ts (relayProtectedErrorMessage)
  @backlog @desktop @mobile
  Scenario: A link refused for the account's tunnel limit says how to free one
    Given the account already has its maximum number of managed tunnels
    When the user links an environment through HAL-C2 Connect
    Then the user is told the relay refused the link because of the limit
    And is told to unlink an environment to free one up

  # Legacy: packages/client-runtime/src/relay/errorPresentation.ts (dpopFailureMessage, DPOP_CLOCK_HINT)
  @backlog @desktop @mobile
  Scenario Outline: A rejected proof of the device's key points to the clock only when that is the reason
    Given HAL-C2 Connect rejects the proof of the device's key and <reason>
    When the user connects to an environment through HAL-C2 Connect
    Then the user is told "Relay rejected the DPoP proof." followed by the hint "<hint>"

    Examples:
      | reason                               | hint                                                                                                                                       |
      | the proof's time is outside its window | Check that automatic date and time is enabled on both devices, then try again.                                                          |
      | it gives no reason                   | Try again. If it still fails, clock skew may be the cause; check that automatic date and time is enabled on both devices.                |
      | it names another reason              | Try again. If the problem continues, copy the trace ID.                                                                                   |

  # Legacy: packages/client-runtime/src/errors/network.ts (NETWORK_BLOCKING_HINT), connection/errors.ts (mapRemoteEnvironmentError)
  @backlog @desktop @mobile
  Scenario Outline: A failure to reach HAL-C2 Connect suggests the network may be filtering it
    Given the client reaches an environment <how>
    When the connection fails because <failure>
    Then the status says <hint>

    Examples:
      | how                    | failure                                  | hint                                                                                        |
      | through HAL-C2 Connect | a request times out                      | that the network may be blocking HAL-C2 Connect, and to try another network such as a phone hotspot |
      | through HAL-C2 Connect | a request cannot reach the host          | that the network may be blocking HAL-C2 Connect, and to try another network such as a phone hotspot |
      | through HAL-C2 Connect | the live connection cannot be opened     | that the network may be blocking HAL-C2 Connect, and to try another network such as a phone hotspot |
      | at a direct address    | a request times out                      | nothing about blocking                                                                      |

  # Legacy: packages/client-runtime/src/relay/managedRelay.ts (timeoutRelayRequest, MANAGED_RELAY_REQUEST_TIMEOUT_MS)
  @backlog @desktop @mobile
  Scenario: A request to HAL-C2 Connect that gets no answer in 10 seconds names what timed out
    Given HAL-C2 Connect does not answer
    When the user opens the list of HAL-C2 Connect environments
    And 10 seconds pass
    Then the user is told the environment listing timed out
    And is given the hint about a filtering network

  # Legacy: packages/client-runtime/src/relay/discovery.ts (validateStatus)
  @backlog @desktop @mobile
  Scenario Outline: A relay status that is about something else is not believed
    Given HAL-C2 Connect answers the status check for "Office Mac" with <wrong>
    When the user opens the list of HAL-C2 Connect environments
    Then "Office Mac" is shown with the error "<message>"
    And the other environments are listed as usual

    Examples:
      | wrong                                    | message                                                    |
      | the status of a different environment    | Relay returned status for a different environment.         |
      | the status of a different endpoint       | Relay returned status for a different environment endpoint. |
      | the description of a different environment | Relay returned a descriptor for a different environment. |

  # Legacy: packages/client-runtime/src/authorization/service.ts (cloud session changed, renewal timeout)
  @backlog @desktop @mobile
  Scenario Outline: A relayed environment whose credential cannot be renewed says so
    Given the client is connected to "Office Mac" through HAL-C2 Connect
    When <event>
    Then the status says "<message>"

    Examples:
      | event                                                        | message                                                              |
      | the user's HAL-C2 Connect sign-in changes while it renews     | Your cloud sign-in changed. Sign in again to authorize the environment. |
      | renewing the environment's credential takes over 30 seconds | Timed out renewing the environment credential.                       |

  @backlog @desktop
  Scenario: An environment this app cannot talk to is marked unsupported
    Given "Office Mac" runs a server this app does not support
    When the user opens the list of HAL-C2 Connect environments
    Then "Office Mac" is marked "Client not supported"
    And it cannot be added

  @backlog @desktop
  Scenario: Installing the relay client asks first and names the version
    Given the relay client is missing
    When the user connects a relayed environment
    Then the user is asked to download and install the managed relay client
    And the question names the version that would be installed
    When the user cancels
    Then nothing is downloaded and the environment is not connected

  @backlog @desktop
  Scenario: Installing the relay client shows which step it is on
    Given the user agreed to install the relay client
    When the install runs
    Then the user sees the current step out of seven, from checking the installation to activating it
    And is asked to keep the app open until it finishes

  @backlog @desktop
  Scenario: A second relay client install request is refused while one is in progress
    Given a relay client install is being confirmed or running
    When another environment asks to install the relay client
    Then the second request is refused saying which installation is in progress

  @backlog @desktop
  Scenario: The account page lists registered environments with how they are reached
    Given the account has a linked MC with a managed tunnel and one that only publishes activity
    When the user opens the HAL-C2 Connect page of their account
    Then each environment shows its name and when it was linked
    And says whether it uses a managed tunnel or publishes activity only

  @backlog @desktop
  Scenario: Deregistering an environment asks first and explains
    Given "Old Laptop" is registered with the account
    When the user chooses to deregister "Old Laptop"
    Then the user is told it will be removed from the account and its access and tunnel revoked
    And that connections on the user's own devices are not changed
    When the user cancels
    Then "Old Laptop" stays registered

  @backlog @desktop
  Scenario: A deregistered environment leaves the account page at once
    Given "Old Laptop" is registered with the account
    When the user confirms deregistering "Old Laptop"
    Then the user is told the server was deregistered and a host space is available
    And "Old Laptop" is no longer listed even before the list refreshes

  @backlog @desktop
  Scenario: A deregistration that fails is reported with its trace ID
    Given deregistering "Old Laptop" fails
    When the user confirms deregistering it
    Then the user is told "Could not deregister server" with the reason
    And the user can copy the trace ID
    And "Old Laptop" stays registered

  @backlog @desktop
  Scenario: The account page lists the phones that receive activity
    Given two phones are registered for HAL-C2 Connect activity
    When the user opens the Mobile clients page of their account
    Then each phone shows its platform, app version and when it last updated
    And whether push notifications and live activities are on

  @backlog @desktop
  Scenario Outline: A phone's alert settings are summarised
    Given a registered phone whose <state>
    When the user opens the Mobile clients page of their account
    Then the phone says "<summary>"

    Examples:
      | state                                              | summary                                                |
      | push notifications are off                         | Push notifications are disabled on this device.       |
      | alerts are on for approvals and failures           | Alerts enabled for approvals, failures.               |
      | push is on but no alert type is selected           | Push notifications are enabled, but no alert types are selected. |

  @backlog @desktop
  Scenario: The Mobile clients page says when no phone is registered
    Given no phone is registered
    When the user opens the Mobile clients page of their account
    Then the user sees that there are no mobile clients

  @backlog @desktop
  Scenario: The Mobile clients page that cannot be loaded says why and can be retried
    Given the app cannot load the account's registered phones
    When the user opens the Mobile clients page of their account
    Then the user is told why
    And can retry

  # The /connect page is served by the hosted app for `hal-c2 connect`'s browser sign-in; the
  # MC side of that flow is in the scenarios above. HAL-C2 has no hosted web app.
  @dropped @desktop
  Scenario: An incomplete connect link asks the user to run the command again
    Given the user opens a hosted connect page without its authorization request
    Then the page says the link is incomplete
    And tells the user to run `hal-c2 connect` again and open the new address

  # The /connect page is served by the hosted app for `hal-c2 connect`'s browser sign-in.
  @dropped @desktop
  Scenario: The hosted connect page signs the user in then forwards the request to the account provider
    Given the user opens the hosted connect page printed by `hal-c2 connect`
    When the user is not signed in
    Then the page asks them to sign in
    And once signed in it sends the terminal's authorization request on to the account provider
