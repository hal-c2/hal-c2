# Sources:
#   apps/mobile/src/features/connection/pairing.ts (host + token, QR payload, scheme defaults)
#   apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx (Scan QR Code, pairing code)
#   apps/mobile/src/features/connection/ConnectionsRouteScreen.tsx
#   apps/mobile/src/features/connection/ConnectionEnvironmentRow.tsx (label, reconnect, remove)
#   apps/mobile/src/features/connection/CloudEnvironmentRows.tsx
#   apps/mobile/src/features/connection/ConnectionTraceId.tsx
#   apps/mobile/src/features/connection/GitHubRoutingSettings.tsx
#   apps/mobile/src/features/cloud/ConnectOnboarding.tsx (Set up HAL-C2 Connect)
#   apps/mobile/src/features/cloud/HalC2ConnectProfilePage.tsx (registered servers)
#   apps/mobile/src/features/cloud/linkEnvironment.ts
#   apps/mobile/app.config.ts (local network usage, camera)
#   apps/mobile-qt/src/Pairing.cpp (one environment at a time: pairing.pair, pairing.forget)
#   apps/mobile-qt/qml/HalC2/Mobile/PairingScreen.qml
#   apps/desktop-qt/qml/HalC2/Bricks/PairingSettings.qml (the environment in Settings, forgetting it, asked first)
#   apps/mobile-qt/qml/HalC2/Mobile/MobileShell.qml (forgetting an environment that cannot be reached)
#   apps/desktop-qt/src/native/PairingExchange.cpp (reading a link, spending its token)
#   apps/desktop-qt/src/native/ConnectionHealthController.cpp (an MC of another protocol, trace id)
#   apps/desktop-qt/qml/HalC2/Bricks/ConnectionNotice.qml (try again, copy trace ID)
# Shared pairing and relay behaviour lives in features/connections/. This file covers the
# phone journey: first launch, scanning a code, and managing environments from a phone.

Feature: Pairing a phone with environments
  A phone has no environment of its own. The user pairs it with one or more environments by
  scanning a code or entering a pairing link, and can later rename, reconnect or remove them.

  @mobile
  Scenario: First launch with no environments invites the user to add one
    Given the app has never been paired
    When the user opens the app
    Then the user is told no environments are connected
    And the user is offered to add an environment

  @backlog @mobile
  Scenario: Scanning a pairing code adds the environment
    Given an environment shows a pairing code
    When the user scans the code
    Then the environment is added to the phone
    And its threads start loading

  @backlog @mobile
  Scenario: Scanning asks for camera access the first time
    Given the app has not been granted camera access
    When the user chooses to scan a pairing code
    Then the phone asks for camera access

  @backlog @mobile
  Scenario: Denied camera access explains how to recover
    Given the user has denied camera access
    When the user chooses to scan a pairing code
    Then the user is told camera access is needed
    And the user is offered to open the system settings

  @backlog @mobile
  Scenario: A code that is not a pairing code is rejected
    When the user scans a code that does not contain a pairing link
    Then the user is told the code is not a valid pairing code
    And no environment is added

  @mobile
  Scenario: Pasting a pairing link adds the environment
    When the user enters a pairing link that carries a token
    And the user adds the environment
    Then the environment is added to the phone

  @backlog @mobile
  Scenario Outline: The address the user types is completed with a sensible scheme
    When the user enters the pairing address "<typed>"
    Then the phone connects to "<resolved>"

    Examples:
      | typed                           | resolved                                |
      | 192.168.1.20:3773#token=abc     | http://192.168.1.20:3773                |
      | devbox.tailnet.ts.net#token=abc | https://devbox.tailnet.ts.net           |
      | https://devbox.example/?token=a | https://devbox.example                  |

  @mobile
  Scenario: A spent or wrong pairing token is refused
    Given the pairing token has already been used
    When the user tries to pair with it
    Then the user is told pairing failed
    And the pairing form keeps what the user entered

  @mobile
  Scenario: An unreachable address reports that the environment cannot be reached
    Given the environment at the pairing address is offline
    When the user tries to pair with it
    Then the user is told the environment could not be reached
    And no environment is added

  @backlog @mobile
  Scenario: Pairing with an environment that is already paired updates it instead of duplicating it
    Given the phone is paired with "My MacBook"
    When the user pairs with "My MacBook" again
    Then "My MacBook" is listed once

  @backlog @mobile
  Scenario: The user renames an environment on the phone
    Given the phone is paired with an environment labelled "devbox"
    When the user renames it to "My MacBook"
    Then the environment is shown as "My MacBook" everywhere on the phone

  @mobile
  Scenario: The user reconnects an environment by hand
    Given an environment has lost its connection
    When the user asks to reconnect it
    Then the phone tries to connect again straight away

  @mobile
  Scenario: The user removes an environment from the phone
    Given the phone is paired with "My MacBook"
    When the user removes "My MacBook" and confirms
    Then "My MacBook" is no longer listed
    And its cached threads are removed from the phone

  @mobile
  Scenario: Cancelling removal keeps the environment
    Given the phone is paired with "My MacBook"
    When the user starts to remove "My MacBook" but cancels
    Then "My MacBook" is still listed

  @mobile
  Scenario: An environment the phone cannot connect to can still be removed
    Given an environment runs a server version the app does not support
    When the user removes it from the connection notice and confirms
    Then "My MacBook" is no longer listed

  @mobile
  Scenario: The user copies a connection trace id for support
    Given an environment connection has a trace id
    When the user copies the trace id
    Then the trace id is on the clipboard

  @backlog @mobile
  Scenario: Signing in to HAL-C2 Connect offers to set up relayed environments
    Given the user has environments registered with HAL-C2 Connect
    When the user signs in to HAL-C2 Connect on the phone
    Then the user is offered to set up HAL-C2 Connect
    And the registered environments are listed to enable

  @backlog @mobile
  Scenario: The user enables a relayed environment during setup
    Given the HAL-C2 Connect setup lists "Office Mac"
    When the user enables "Office Mac"
    Then "Office Mac" is added to the phone through the relay

  @backlog @mobile
  Scenario: The user can decline HAL-C2 Connect setup for good
    Given the HAL-C2 Connect setup is showing
    When the user asks not to see it again
    Then the setup does not reappear for that account on this phone

  @backlog @mobile
  Scenario: A relayed environment can be removed from this phone only
    Given the phone uses "Office Mac" through HAL-C2 Connect
    When the user removes "Office Mac" from this phone
    Then "Office Mac" is no longer listed on this phone
    And "Office Mac" stays registered with HAL-C2 Connect

  @backlog @mobile
  Scenario: Only a directly paired environment can be linked to HAL-C2 Connect
    Given the phone reaches "Office Mac" only through the relay
    Then the user is not offered to link "Office Mac" to HAL-C2 Connect

  @backlog @mobile
  Scenario: The user deregisters a server from their HAL-C2 Connect profile
    Given "Old Laptop" is registered with the user's HAL-C2 Connect account
    When the user deregisters "Old Laptop" and confirms
    Then "Old Laptop" is no longer registered

  @backlog @mobile
  Scenario Outline: The user chooses how an environment may use GitHub
    Given the phone is paired with "My MacBook"
    When the user sets GitHub access for "My MacBook" to "<level>"
    Then agents on "My MacBook" may <ability>

    Examples:
      | level        | ability                                |
      | Off          | not use GitHub                         |
      | Read PRs     | read pull requests only                |
      | Read and act | read and act on pull requests          |

  @mobile
  Scenario: An environment running an incompatible version is explained
    Given an environment runs a server version the app does not support
    Then the user is told to use compatible versions of the app and server
    And the phone does not keep trying to sync it
