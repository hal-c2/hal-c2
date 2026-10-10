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
#   apps/mobile/src/features/cloud/ConnectOnboardingRouteScreen.tsx (setup sheet, pull to refresh, no cloud config)
#   apps/mobile/src/features/cloud/connectOnboarding.ts, connectOnboardingNavigation.ts, connectOnboardingOptOut.ts
#   apps/mobile/src/features/cloud/CloudAuthProvider.tsx (sign-out and account switch cleanup)
#   apps/mobile/src/features/cloud/cloudEnvironmentPresentation.ts (relay status texts)
#   apps/mobile/src/features/connection/ConnectionEnvironmentRow.tsx (switch, edit label and address, managed by Connect)
#   apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx (add button, pairing state)
#   apps/mobile/src/state/use-remote-environment-registry.ts (unsupported client notice, pairing failure text, form cleared on success)
#   apps/mobile/src/lib/storage.test.ts, connection.ts (what the phone keeps of an environment, unreadable saved lists)
#   apps/mobile/src/lib/authClientMetadata.ts (how the phone presents itself when it pairs)
#   apps/mobile/app.config.ts (local network usage, camera)
#   apps/mobile-qt/src/Pairing.cpp (one environment at a time: pairing.pair, pairing.forget; pairing with
#     another: pairing.add, pairing.cancel; a link from outside the app is shown and never spent: openLink;
#     a session is saved before it is paired with)
#   apps/mobile-qt/src/Scanner.cpp (the camera while the scanner shows, camera access, a code that is not a pairing
#     code, a camera that gives no picture: scanner.retry)
#   apps/mobile-qt/src/ScanCamera.cpp (a camera that does not start or stops, a device with none)
#   apps/mobile-qt/src/QrReader.cpp (reading a QR code off a camera frame)
#   apps/mobile-qt/src/MobileApp.cpp (the handler of hal-c2: links)
#   apps/mobile-qt/android/AndroidManifest.xml (hal-c2://pair, the camera permission)
#   apps/mobile-qt/qml/HalC2/Mobile/PairingScreen.qml
#   apps/mobile-qt/qml/HalC2/Mobile/ScanScreen.qml
#   apps/desktop-qt/qml/HalC2/Bricks/PairingSettings.qml (the environment in Settings, pairing with another,
#     forgetting it, asked first)
#   apps/mobile-qt/qml/HalC2/Mobile/MobileShell.qml (forgetting an environment that cannot be reached)
#   apps/desktop-qt/src/native/PairingExchange.cpp (reading a link, a link nobody typed, spending its token)
#   apps/desktop-qt/src/native/ConnectionHealthController.cpp (an MC of another protocol, trace id)
#   apps/desktop-qt/qml/HalC2/Bricks/ConnectionNotice.qml (try again, copy trace ID)
# Shared pairing and relay behaviour lives in features/connections/. This file covers the
# phone journey: first launch, scanning a code, a link that opens the app to pair, and managing
# environments from a phone.

Feature: Pairing a phone with environments
  A phone has no environment of its own. The user pairs it with one or more environments by
  scanning a code or entering a pairing link, and can later rename, reconnect or remove them.

  @mobile
  Scenario: First launch with no environments invites the user to add one
    Given the app has never been paired
    When the user opens the app
    Then the user is told no environments are connected
    And the user is offered to add an environment

  @mobile
  Scenario: Scanning a pairing code adds the environment
    Given an environment shows a pairing code
    When the user scans the code
    Then the environment is added to the phone
    And its threads start loading

  @mobile
  Scenario Outline: A pairing code is scanned however the device is held
    Given the app runs on <device>
    And an environment shows a pairing code
    When the user scans the code
    Then the environment's threads are listed

    Examples:
      | device                |
      | a phone on its side   |
      | a tablet              |
      | a tablet held upright |

  @mobile
  Scenario: Scanning asks for camera access the first time
    Given the app has not been granted camera access
    When the user chooses to scan a pairing code
    Then the phone asks for camera access

  @mobile
  Scenario: Denied camera access explains how to recover
    Given the user has denied camera access
    When the user chooses to scan a pairing code
    Then the user is told camera access is needed
    And the user is offered to open the system settings

  @mobile
  Scenario: A code that is not a pairing code is rejected
    When the user scans a code that does not contain a pairing link
    Then the user is told the code is not a valid pairing code
    And no environment is added

  # New behaviour: the React Native app closed its scanner on the first code it read.
  @mobile
  Scenario: The scanner keeps looking after a code that is not a pairing code
    Given an environment shows a pairing code
    When the user scans a code that does not contain a pairing link
    Then the scanner keeps looking
    When the user scans the code
    Then the environment is added to the phone

  @mobile
  Scenario Outline: Leaving the scanner turns the camera off
    Given the user is scanning for a pairing code
    When the user leaves the scanner by <way>
    Then the camera is off
    And the user is offered to add an environment

    Examples:
      | way               |
      | its back button   |
      | the system's back |

  @mobile
  Scenario: The camera is off while another app is in front
    Given the user is scanning for a pairing code
    When the user switches to another app
    Then the camera is off

  @mobile
  Scenario: Returning to the app resumes scanning
    Given the user is scanning for a pairing code
    When the user switches to another app and back
    Then the scanner is looking again

  # New behaviour, the next three: the React Native app showed an empty preview for a camera that
  # gave no picture.
  @mobile
  Scenario Outline: A camera that gives no picture is explained
    Given the user has allowed camera access
    And <trouble>
    When the user chooses to scan a pairing code
    Then the user is told <explanation>
    And the camera is off

    Examples:
      | trouble                         | explanation               |
      | another app is using the camera | the camera cannot be used |
      | the device has no camera        | the device has no camera  |

  @mobile
  Scenario: A camera that stops while scanning is explained
    Given the user is scanning for a pairing code
    When another app takes the camera
    Then the user is told the camera cannot be used
    And the camera is off

  @mobile
  Scenario: The user tries a camera that stopped again without leaving the scanner
    Given the user is scanning for a pairing code
    And another app has taken the camera
    When the user tries the camera again
    Then the scanner is looking again

  @mobile
  Scenario: Pasting a pairing link adds the environment
    When the user enters a pairing link that carries a token
    And the user adds the environment
    Then the environment is added to the phone

  # Likely already implemented: apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx
  @backlog @mobile
  Scenario: An environment cannot be added without an address
    Given the pairing form has no address
    Then the user cannot add the environment

  @backlog @mobile
  Scenario: The phone shows it is pairing while it waits
    Given the pairing form has an address and a pairing code
    When the user adds the environment
    Then the form says it is pairing
    And the user cannot add the environment a second time until pairing ends

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
  Scenario: An environment this app version cannot pair with is refused in a notice
    Given the environment at the pairing address runs a version this app does not support
    When the user tries to pair with it
    Then the user is shown a notice titled "Client not supported" that says why
    And no environment is added

  @backlog @mobile
  Scenario: The pairing form is emptied once the environment is added
    Given the pairing form has an address and a pairing code
    When the user adds the environment
    Then the environment is added to the phone
    And the pairing form is empty

  @backlog @mobile
  Scenario: A pairing that fails without a reason says so plainly
    Given the environment fails the pairing without saying why
    When the user tries to pair with it
    Then the user is told "Failed to pair with the environment."
    And no environment is added

  @backlog @mobile
  Scenario: An iPhone that is refused local network access is told how to allow it
    Given the phone has not allowed HAL-C2 to find devices on the local network
    When the user tries to pair with an environment on the local network
    Then the user is told to allow local network access for HAL-C2 in the system settings
    And no environment is added

  # New behaviour, the next two: the session a link buys is saved on the phone before the phone
  # pairs with it. The link is spent by then, so the user is told to ask for a fresh one.
  @mobile
  Scenario: A session the phone cannot save is not paired with
    Given the phone has no room to save a session
    When the user enters a pairing link that carries a token
    And the user adds the environment
    Then the user is told the session could not be saved
    And the pairing form keeps what the user entered
    And no environment is added

  @mobile
  Scenario: A session the phone cannot save does not replace the environment it has
    Given the phone is paired with "My MacBook"
    And the phone has no room to save a session
    When the user tries to pair with the environment "Office Mac" instead
    Then the user is told the session could not be saved
    And the pairing form keeps what the user entered
    And the phone is still paired with "My MacBook" and connected

  @mobile
  Scenario: Pairing with an environment that is already paired updates it instead of duplicating it
    Given the phone is paired with "My MacBook"
    When the user pairs with "My MacBook" again
    Then "My MacBook" is listed once

  # New behaviour, from here to the links: the phone keeps one environment (apps/mobile-qt Pairing),
  # so pairing with another gives up the one it has, and the user is told before it does.
  @mobile
  Scenario: A paired phone is told what pairing with another environment replaces
    Given the phone is paired with "My MacBook"
    When the user chooses to pair with another environment
    Then the user is told that pairing replaces "My MacBook"

  @mobile
  Scenario: Backing out of pairing with another environment keeps the current one
    Given the phone is paired with "My MacBook"
    When the user starts to pair with another environment but goes back
    Then "My MacBook" is still listed

  @mobile
  Scenario: Pairing a paired phone with another environment replaces the first
    Given the phone is paired with "My MacBook"
    When the user pairs with the environment "Office Mac" instead
    Then "Office Mac" is listed in place of "My MacBook"

  # New behaviour: a link that pairs, which the environment's pairing page offers a phone whose own
  # camera read the code. Anyone can write such a link, so it is never paired with by itself.
  @mobile
  Scenario: A pairing link opened from outside the app fills the pairing form without pairing
    Given the app has never been paired
    When the user follows a pairing link from outside the app
    Then the pairing form holds the link
    And the user is told which address the link would pair with
    And no environment is added

  @mobile
  Scenario: The user pairs with a link opened from outside the app
    Given the user followed a pairing link from outside the app
    When the user adds the environment
    Then the environment is added to the phone

  @mobile
  Scenario: A pairing link that opens the app while it is scanning takes the scanner's place
    Given the user is scanning for a pairing code
    When the user follows a pairing link from outside the app
    Then the camera is off
    And the pairing form holds the link
    And no environment is added

  @mobile
  Scenario: A pairing link opened from outside a paired app names the environment it would replace
    Given the phone is paired with "My MacBook"
    When the user follows a pairing link to another environment from outside the app
    Then the user is told which address the link would pair with
    And the user is told that pairing replaces "My MacBook"
    And the phone stays paired with "My MacBook"

  @mobile
  Scenario: Turning down a pairing link opened from outside the app keeps the current environment
    Given the phone is paired with "My MacBook"
    And the user followed a pairing link to another environment from outside the app
    When the user goes back without pairing
    Then the phone stays paired with "My MacBook"

  @mobile
  Scenario Outline: A link from outside the app that is not a pairing link changes nothing
    Given the phone is paired with "My MacBook"
    When the user follows a link from outside the app that <problem>
    Then the user is told the link is not a pairing link
    And the phone stays paired with "My MacBook"

    Examples:
      | problem                                    |
      | carries no pairing link                    |
      | carries something other than a web address |
      | carries another link into the app          |
      | leads elsewhere in the app                 |

  @mobile
  Scenario: A link that is not a pairing link is refused before any environment is paired
    Given the app has never been paired
    When the user follows a link from outside the app that carries no pairing link
    Then the user is told the link is not a pairing link
    And no environment is added

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

  # Likely already implemented: apps/mobile/src/features/connection/ConnectionEnvironmentRow.tsx
  @backlog @mobile
  Scenario: The user switches an environment off without removing it
    Given the phone is paired with "My MacBook"
    When the user switches "My MacBook" off
    Then "My MacBook" is shown as off
    And "My MacBook" stays listed with its saved credential and cached threads
    And the phone stops connecting to "My MacBook"

  @backlog @mobile
  Scenario: A switched-off environment shows none of its connection problems
    Given the phone is paired with "My MacBook" and "Office Mac"
    And "My MacBook" cannot be reached
    When the user switches "My MacBook" off
    Then the phone shows no connection problem for "My MacBook"
    And the phone's overall connection follows "Office Mac" alone

  @backlog @mobile
  Scenario: The user switches an environment back on
    Given "My MacBook" is switched off
    When the user switches "My MacBook" on
    Then the phone connects to "My MacBook"
    And its threads are listed again

  @backlog @mobile
  Scenario: A switched-off environment cannot be reconnected by hand
    Given "My MacBook" is switched off
    When the user opens the details of "My MacBook"
    Then reconnecting is not offered until "My MacBook" is switched on

  @backlog @mobile
  Scenario: An environment the app cannot talk to cannot be switched on
    Given an environment runs a server version the app does not support
    Then the user cannot switch it on
    And it is explained as not supported rather than shown as off

  @backlog @mobile
  Scenario: The user changes the address of an environment on the phone
    Given the phone is paired with an environment at "192.168.1.100:8080"
    When the user changes its address to "192.168.1.20:8080" and saves
    Then the environment is listed with the address "192.168.1.20:8080"

  @backlog @mobile
  Scenario: An environment that cannot be updated says why
    Given the phone is paired with "My MacBook"
    And the phone cannot save the change
    When the user renames "My MacBook" and saves
    Then the user is told the environment could not be updated, with the reason
    And what the user typed is still in the form

  @backlog @mobile
  Scenario: An environment managed by HAL-C2 Connect is not edited by hand
    Given the phone uses "Office Mac" through HAL-C2 Connect
    When the user opens the details of "Office Mac"
    Then the user is told it is managed by HAL-C2 Connect and its tunnel details update automatically
    And its label and address cannot be changed
    And the user can still reconnect it and remove it from the phone

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

  # Likely already implemented: apps/mobile/src/features/cloud/HalC2ConnectProfilePage.tsx
  @backlog @mobile
  Scenario: The registered servers say when they were linked
    Given "Old Laptop" is registered with the user's HAL-C2 Connect account without a link date
    When the user opens their registered servers
    Then "Old Laptop" says its link date is unavailable

  @backlog @mobile
  Scenario: The registered servers say they are loading
    Given the user's registered servers are being fetched
    When the user opens their registered servers
    Then the user is told the environments are loading

  @backlog @mobile
  Scenario: Registered servers that cannot be loaded say why and can be refreshed
    Given HAL-C2 Connect cannot be reached
    When the user opens their registered servers
    Then the user is told why the servers could not be loaded
    And the user can copy the trace ID
    When the user pulls down to refresh
    Then the phone asks HAL-C2 Connect for the registered servers again

  @backlog @mobile
  Scenario: An account with no registered servers says how to link one
    Given the user has no server registered with HAL-C2 Connect
    When the user opens their registered servers
    Then the user is told no servers are registered
    And the user is told to link a server from its own settings

  @backlog @mobile
  Scenario: Only one server is deregistered at a time
    Given "Old Laptop" and "Old Desktop" are registered with the user's HAL-C2 Connect account
    And the user confirmed deregistering "Old Laptop"
    When the deregistration is still in progress
    Then "Old Desktop" cannot be deregistered yet

  @backlog @mobile
  Scenario: Signing out of HAL-C2 Connect removes the relayed environments from the phone
    Given the phone uses "Office Mac" through HAL-C2 Connect
    When the user signs out of HAL-C2 Connect
    Then "Office Mac" is no longer listed on this phone
    And "Office Mac" stays registered with HAL-C2 Connect

  @backlog @mobile
  Scenario: Signing out of HAL-C2 Connect forgets the phone's relay sign-in
    Given the phone has used the relay with the account "alice"
    When the user signs out of HAL-C2 Connect
    Then the phone no longer holds a relay credential for "alice"
    And the phone is no longer registered for agent activity alerts under "alice"

  @backlog @mobile
  Scenario: Relayed environments already on the phone stay listed without a HAL-C2 Connect session
    Given the phone has "Office Mac" saved through HAL-C2 Connect
    And the app build has no HAL-C2 Connect
    When the user opens the list of environments
    Then "Office Mac" is listed and can be switched off or removed
    And no other environments of the account are offered

  @backlog @mobile
  Scenario: The set up of HAL-C2 Connect is closed when the user signs out before it opens
    Given the user has just signed in to HAL-C2 Connect
    When the user signs out before the setup is shown
    Then the setup is not shown

  @backlog @mobile
  Scenario: The set up of HAL-C2 Connect is shown when the phone cannot tell whether it was declined
    Given the phone cannot read whether the user declined the setup for this account
    When the user signs in to HAL-C2 Connect
    Then the user is offered to set up HAL-C2 Connect

  @backlog @mobile
  Scenario: The set up of HAL-C2 Connect asks a signed-out user to sign in
    Given the setup of HAL-C2 Connect is showing
    And the user signed out of HAL-C2 Connect
    Then the user is told to sign in to their HAL-C2 account to set up HAL-C2 Connect
    And the user is not offered to decline the setup

  @backlog @mobile
  Scenario: The set up of HAL-C2 Connect refreshes the account's environments when pulled down
    Given the setup of HAL-C2 Connect is showing
    When the user pulls down to refresh
    Then the phone asks HAL-C2 Connect for the account's environments again

  @backlog @mobile
  Scenario: A build without HAL-C2 Connect closes its setup
    Given the app build has no HAL-C2 Connect
    When a link opens the setup of HAL-C2 Connect
    Then the setup closes straight away

  @backlog @mobile
  Scenario: The account's environments say they are loading
    Given the user is signed in to HAL-C2 Connect
    And the account's environments are being fetched
    When the user opens the list of environments
    Then the user is told the linked cloud environments are loading

  @backlog @mobile
  Scenario: Environments of the account that cannot be loaded say why and can be tried again
    Given the user is signed in to HAL-C2 Connect
    And HAL-C2 Connect cannot be reached
    When the user opens the list of environments
    Then the user is told the HAL-C2 Connect environments could not be loaded, with the reason
    And the user can copy the trace ID
    And environments already connected through HAL-C2 Connect are still listed
    When the user tries again
    Then the phone asks HAL-C2 Connect for the account's environments again

  @backlog @mobile
  Scenario Outline: An environment of the account says what is known of its relay
    Given the account has "Office Mac" whose relay <state>
    When the user opens the list of environments
    Then "Office Mac" says <status>

    Examples:
      | state                      | status                              |
      | is being checked           | available, checking relay status    |
      | answers with no status     | available, relay status unknown     |
      | reports it is online       | available, relay online             |
      | reports it is offline      | that the relay is offline           |

  @backlog @mobile
  Scenario: An environment of the account can be inspected for its error
    Given the account has "Old Laptop" whose relay reports an error
    When the user taps "Old Laptop"
    Then the full error is shown
    And the user can copy its trace ID

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

  @backlog @mobile
  Scenario: A short-lived relay token is not kept on the phone
    Given the phone uses "Office Mac" through HAL-C2 Connect
    When the app is closed and opened again
    Then "Office Mac" is still listed
    And the phone asks HAL-C2 Connect for a fresh token before connecting

  @backlog @mobile
  Scenario: A list of environments the phone cannot read is not shown as a crash
    Given the saved list of environments on the phone is unreadable
    When the user opens the app
    Then the environments list is empty
    And the user can pair again

  @backlog @mobile
  Scenario: Saving an environment is not done over a list the phone could not read
    Given the phone's secure store cannot be read
    When the user pairs with "Office Mac"
    Then "Office Mac" is not added
    And the environments the phone already had are not erased

  @backlog @mobile
  Scenario Outline: The environment lists the phone by what kind of device it is
    Given the user pairs from <device> running <system>
    When the user looks at the environment's authorized clients
    Then the phone is listed as "HAL-C2 Mobile", a <kind>, with the system "<os> <major>" and the model "<model>"

    Examples:
      | device          | system         | kind   | os      | major | model             |
      | an iPhone 15 Pro | iOS 18.2       | phone  | iOS     | 18    | iPhone 15 Pro     |
      | a Pixel 9       | Android 15.2.1 | phone  | Android | 15    | Pixel 9           |
      | an iPad Pro     | iPadOS 18.2    | tablet | iOS     | 18    | iPad Pro 13-inch  |

  @backlog @mobile
  Scenario: The environment is told the app version the phone runs
    Given the phone runs app version "1.2.3"
    When the user pairs with "My MacBook"
    Then "My MacBook" lists the phone with the app version "1.2.3"
