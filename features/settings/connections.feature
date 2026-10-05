# Sources:
#   apps/web/src/components/settings/ConnectionsSettings.tsx
#   apps/desktop-qt/src/native/ConnectionsController.cpp, apps/desktop-qt/qml/HalC2/Bricks/ConnectionsSettings.qml
#   apps/web/src/components/settings/ConnectionsSettings.logic.ts
#   apps/web/src/components/settings/pairingUrls.ts
#   apps/web/src/components/settings/EnvironmentRow.tsx
#   apps/web/src/components/settings/RedactedSensitiveText.tsx
#   apps/desktop-qt/parity/features.backlog.test.ts (SSH environments, network access)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (HAL-C2 Connect link)

Feature: Connections settings
  The Connections page shows this machine's server, the devices allowed to reach it, and the
  other environments this device connects to. Pairing itself, HAL-C2 Connect and load balancing are
  specified in their own domains; this file covers the page and the effect of each control.

  Background:
    Given the user has opened the Connections settings
    And the user's session may manage this machine's access

  Rule: This machine

    # What each update action does is in settings/updates.feature.
    @backlog @desktop
    Scenario Outline: The version line says whether this machine is current
      Given this machine's server is <state>
      Then the version line reads "<label>"

      Examples:
        | state                          | label          |
        | on the newest release          | Up to date     |
        | behind release 1.4.0           | Update to 1.4.0 |
        | failed its last update         | Retry update   |

    @backlog @desktop
    Scenario: Turning on network access asks before restarting
      Given network access is off
      When the user turns on network access
      Then the user is asked to confirm restarting and enabling network access

    @backlog @desktop
    Scenario: Confirming network access restarts the server on the network
      Given the user is asked to confirm enabling network access
      When the user confirms
      Then the server restarts listening on the local network
      And an address other devices can use is listed

    @backlog @desktop
    Scenario: Turning off network access restarts the server on this machine only
      Given network access is on
      When the user turns off network access and confirms
      Then the server restarts listening only on this machine

    @backlog @desktop
    Scenario: A network access change that fails is reported
      Given changing network access fails
      When the user turns on network access and confirms
      Then the user is told network access could not be updated
      And network access stays off

    @backlog @desktop
    Scenario: Choosing the default address for pairing
      Given this machine has a local network address and a Tailscale address
      When the user makes the Tailscale address the default
      Then new pairing links use the Tailscale address

    @backlog @desktop
    Scenario Outline: Tailscale HTTPS needs a valid port
      Given the user is setting up Tailscale HTTPS
      When the user enters the port "<port>"
      Then setup is <outcome>

      Examples:
        | port  | outcome  |
        | 443   | allowed  |
        | 0     | refused  |
        | 70000 | refused  |

    @backlog @desktop
    Scenario: Setting up Tailscale HTTPS serves this machine over HTTPS
      Given the user is setting up Tailscale HTTPS on port 443
      When the user confirms
      Then this machine is reachable over HTTPS on the tailnet

    @backlog @desktop
    Scenario: Disabling Tailscale HTTPS asks first and stops serving over HTTPS
      Given Tailscale HTTPS is set up
      When the user disables Tailscale HTTPS and confirms
      Then this machine is no longer served over HTTPS on the tailnet

    @backlog @desktop
    Scenario: A Tailscale HTTPS change that fails is reported
      Given Tailscale is not signed in
      When the user sets up Tailscale HTTPS
      Then the user is told Tailscale HTTPS could not be set up

    @backlog @desktop
    Scenario Outline: The WSL backend chooses where agents run on Windows
      Given the machine runs Windows with WSL installed
      When the user chooses to run <choice>
      Then agents run <result>

      Examples:
        | choice                        | result                          |
        | both Windows and WSL          | on Windows and in WSL           |
        | WSL only                      | in the chosen WSL distribution  |
        | on Windows                    | on Windows only                 |

    @backlog @desktop
    Scenario: Linking this machine to HAL-C2 Connect needs a signed-in account
      Given the user is not signed in to HAL-C2 Connect
      When the user looks at the HAL-C2 Connect link
      Then the link cannot be turned on
      And the user is told to sign in to HAL-C2 Connect

    @backlog @desktop
    Scenario: Linking and unlinking this machine to HAL-C2 Connect
      Given the user is signed in to HAL-C2 Connect
      When the user links this machine
      Then the user is told this machine is linked
      When the user unlinks this machine
      Then the user is told this machine is unlinked

    @backlog @desktop
    Scenario: Publishing agent activity can be turned on and off
      Given this machine is linked to HAL-C2 Connect
      When the user turns on publishing agent activity
      Then agent activity from this machine is shared with the user's other devices
      When the user turns it off
      Then agent activity is no longer shared

    @desktop
    Scenario: A session without administrative access sees this machine read-only
      Given the user's session may not manage this machine's access
      When the user looks at this machine
      Then its controls cannot be changed
      And the user is told administrative access is required

  Rule: Authorized clients

    @desktop
    Scenario: Creating a pairing link with chosen permissions
      When the user creates a pairing link labelled "Phone" allowed to view the environment and operate tasks
      Then a pairing link labelled "Phone" is listed with those permissions and its expiry

    @desktop
    Scenario: A pairing link needs at least one permission
      When the user tries to create a pairing link with no permissions
      Then the user is told to select at least one permission
      And no link is created

    @desktop
    Scenario: A pairing link that cannot be created is reported
      Given the server refuses to create pairing links
      When the user creates a pairing link
      Then the user is told the pairing URL could not be created

    @desktop
    Scenario: Copying a pairing link or its code
      Given a pairing link is listed
      When the user copies the link
      Then the link is on the clipboard
      And the user is told it was copied

    @desktop
    Scenario: A copy that the clipboard refuses reveals the link instead
      Given the clipboard is unavailable
      When the user copies a pairing link
      Then the link is shown so the user can copy it by hand

    @backlog @desktop
    Scenario: A pairing link can be shared as a QR code except on this machine's own address
      Given a pairing link is listed
      When the user chooses to reach this machine via its local network address
      Then a QR code for the link is offered
      When the user chooses this machine's loopback address
      Then no QR code is offered

    @desktop
    Scenario: Revoking a pairing link stops it from pairing
      Given a pairing link is listed
      When the user revokes it
      Then the link is no longer listed
      And a device can no longer pair with it

    @desktop
    Scenario: Revoking a connected client signs it out
      Given the client "Phone" is connected
      When the user revokes "Phone"
      Then "Phone" is signed out and no longer listed

    @desktop
    Scenario: Revoking every other client keeps the current one
      Given three clients are listed including this one
      When the user revokes the others
      Then only this client is listed
      And the user is told 2 clients were revoked

    @desktop
    Scenario: Nothing is paired yet
      Given there are no pairing links or client sessions
      Then the user is told there are no pairing links or client sessions

    @desktop
    Scenario: A session without administrative access cannot manage who reaches this machine
      Given the user's session may not manage this machine's access
      Then the user is told administrative access is required
      And no pairing links or clients are listed

  Rule: Other environments

    # MCs join only by clustering, so the page pairs no environment itself: it leads to
    # the Cluster settings (connections/cluster.feature), which add and remove machines.
    @desktop
    Scenario: Other machines are added from the Cluster settings
      When the user goes on to this machine's cluster
      Then the window shows the settings section "/settings/cluster"

    @dropped @desktop
    Scenario: Adding an environment from a pairing link
      When the user adds an environment with a host and pairing code
      Then the environment is connected and listed
      And the user is told the environment connected

    @backlog @desktop
    Scenario: Adding an environment over SSH
      Given the user's SSH config names the host "devbox"
      When the user adds an environment over SSH to "devbox"
      Then HAL-C2 starts on "devbox" and it is listed as an environment

    @dropped @desktop
    Scenario: An environment that cannot be added is reported
      Given the host does not answer
      When the user adds an environment with that host
      Then the user is told the backend could not be added

    @dropped @desktop
    Scenario: A pairing link that was already used cannot add an environment
      Given a pairing link from "Build box" that was already used
      When the user adds an environment with that link
      Then the user is told to ask for a fresh pairing link
      And no environment is added

    @dropped @desktop
    Scenario: An environment that revoked this machine asks to be paired again
      Given "Build box" is linked and has revoked this machine's access
      Then its row reads "Access refused: pair it again"
      When the user adds "Build box" again from a fresh pairing link
      Then its row reads "Connected"

    @dropped @desktop
    Scenario: An environment that stops answering is shown offline
      Given "Build box" is linked and stops answering
      Then its row reads "Offline"

    @backlog @desktop
    Scenario Outline: Each environment says how it is connected
      Given the environment "Build box" is <state>
      Then its row reads "<label>"

      Examples:
        | state                            | label                         |
        | switched off                     | Off                           |
        | connected                        | Connected                     |
        | connecting                       | Connecting                    |
        | reconnecting after a timeout     | Reconnecting: timeout         |
        | running an unsupported version   | Client not supported          |
        | refusing the connection          | Connection failed: refused    |
        | unreachable                      | Offline                       |

    @backlog @desktop
    Scenario Outline: Each environment says how this device reaches it
      Given the environment "Build box" is reached <route>
      Then its row starts with "<label>"

      Examples:
        | route                    | label              |
        | through HAL-C2 Connect       | HAL-C2 Connect         |
        | over SSH as ada@devbox   | SSH ada@devbox     |
        | through WSL              | WSL                |

    @backlog @desktop
    Scenario: Switching an environment off keeps it saved
      Given "Build box" is connected
      When the user switches "Build box" off
      Then this device disconnects from "Build box"
      And "Build box" stays listed as off
      When the user switches it back on
      Then this device connects to "Build box" again

    @dropped @desktop
    Scenario: Removing an environment forgets it on this device
      When the user removes "Build box" from this device and confirms
      Then its pairing, credentials and cached threads are forgotten here
      And "Build box" is no longer listed

    @dropped @desktop
    Scenario: Cancelling removal keeps the environment
      When the user starts removing "Build box" and cancels
      Then "Build box" is still listed

    @backlog @desktop
    Scenario: An environment on an older server can be updated from here
      Given "Build box" runs an older server than this client
      When the user updates "Build box"
      Then "Build box" updates and reconnects

    # The update itself, including confirming desktop hosts first, is owned by
    # settings/updates.feature (Updating a server); this is the Connections entry point.
    @backlog @desktop
    Scenario: Every outdated environment can be updated at once
      Given "Build box" and "Laptop" run older servers
      When the user updates all environments
      Then both environments update

    @backlog @desktop
    Scenario: A trace ID can be copied for support
      When the user copies the trace ID of "Build box"
      Then its trace ID is on the clipboard

    @backlog @desktop
    Scenario: Choosing an icon for an environment
      When the user chooses a rocket icon for "Build box"
      Then "Build box" is shown with the rocket icon wherever environments are listed
      When the user clears the icon
      Then "Build box" is shown with its default icon
