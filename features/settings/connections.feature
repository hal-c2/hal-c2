# Sources:
#   apps/web/src/components/settings/ConnectionsSettings.tsx
#   apps/desktop/src/backend/DesktopServerExposure.ts, tailscaleEndpointProvider.ts (network access, advertised addresses, Tailscale Serve)
#   apps/desktop-qt/src/native/ConnectionsController.cpp, apps/desktop-qt/qml/HalC2/Bricks/ConnectionsSettings.qml
#   apps/desktop-qt/qml/HalC2/Bricks/QrCode.qml, apps/desktop-qt/src/native/QrCode.cpp (a pairing link as a QR code)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.createPairingLink: the address a link's machine is reached at)
#   apps/web/src/components/settings/ConnectionsSettings.logic.ts
#   apps/web/src/components/settings/ConnectionsSettings.logic.test.ts (WSL row visibility, WSL enable staging, share panel address)
#   apps/web/src/components/settings/pairingUrls.ts
#   apps/web/src/components/settings/EnvironmentRow.tsx
#   apps/web/src/connection/clientMetadata.ts (what the app presents when it pairs)
#   apps/web/src/state/desktopSshHosts.ts (suggested SSH hosts: ranking and matching)
#   packages/ssh/src/config.ts (SSH host discovery: config aliases, Include files, known hosts)
#   packages/tailscale/src/tailscale.ts (tailnet name and addresses, serve port, status timeout)
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

    # Legacy: apps/desktop/src/backend/DesktopServerExposure.ts (setMode, resolveRuntimeState)
    @backlog @desktop
    Scenario: Network access cannot be turned on when this machine has no address to be reached at
      Given this machine has no network address other than its own and no Tailscale address
      When the user turns on network access and confirms
      Then the user is told no reachable network address is available for network access
      And network access stays off

    @backlog @desktop
    Scenario: A machine with only a Tailscale address can turn on network access
      Given this machine has no local network address but is on a tailnet
      When the user turns on network access and confirms
      Then the server restarts listening on the network
      And only the tailnet addresses are offered for pairing

    @backlog @desktop
    Scenario: A saved network access choice with no address to use starts on this machine only
      Given the user turned on network access earlier
      And this machine now has no network address to be reached at
      When the app starts
      Then the server listens only on this machine
      And the choice is kept for when an address is back

    @backlog @desktop
    Scenario Outline: The address advertised for the local network skips addresses nobody else can use
      Given this machine has <addresses>
      When the user opens the Connections settings with network access on
      Then the local network address offered for pairing is <offered>

      Examples:
        | addresses                                                                     | offered                           |
        | a wired address and a Tailscale address                                       | the wired address                 |
        | only a loopback address and a link-local address starting 169.254             | none                              |
        | a wired address, and the operator named the host "desk.local" at launch       | "desk.local"                      |

    @backlog @desktop
    Scenario: HTTPS addresses an operator configured are listed as custom addresses
      Given the operator launched the app with two HTTPS addresses for this machine and one that is not a valid address
      When the user opens the Connections settings
      Then the two HTTPS addresses are listed as custom HTTPS addresses that anyone can reach
      And the invalid one is not listed and does not hide the others

    @backlog @desktop
    Scenario: Tailscale is not asked about while the user has not opted into network exposure
      Given network access is off
      And Tailscale HTTPS is off
      When the user opens the Connections settings
      Then HAL-C2 does not query the Tailscale app for this machine's tailnet name

    @backlog @desktop
    Scenario: A tailnet HTTPS name is available only while Tailscale Serve actually answers on it
      Given Tailscale HTTPS is on
      And Tailscale knows this machine's tailnet name
      When Tailscale Serve does not answer on that name
      Then the tailnet name is listed as unavailable and asks for Tailscale HTTPS to be configured
      When Tailscale Serve answers on that name
      Then the tailnet name is listed as available for HTTPS clients

    # Legacy: packages/tailscale/src/tailscale.ts (isTailscaleIpv4Address: 100.64.0.0/10)
    @backlog @desktop
    Scenario Outline: Only an address inside the tailnet range is offered as a Tailscale address
      Given Tailscale reports the address "<address>" for this machine
      When the user opens the Connections settings with network access on
      Then that address is <offered> as a Tailscale address

      Examples:
        | address         | offered     |
        | 100.64.0.1      | offered     |
        | 100.127.255.254 | offered     |
        | 100.63.255.255  | not offered |
        | 100.128.0.1     | not offered |
        | 192.168.1.20    | not offered |

    # Legacy: packages/tailscale/src/tailscale.ts (normalizeMagicDnsName)
    @backlog @desktop
    Scenario: The tailnet name is shown the way a person writes it
      Given Tailscale reports this machine's name as "laptop.tail1234.ts.net."
      When the user opens the Connections settings
      Then the tailnet name is "laptop.tail1234.ts.net" with no dot at the end

    # Legacy: packages/tailscale/src/tailscale.ts (TAILSCALE_STATUS_TIMEOUT = 1.5 s)
    @backlog @desktop
    Scenario: A Tailscale that is slow to answer does not hold up the page
      Given Tailscale is installed but does not answer when asked about this machine
      When the user opens the Connections settings with network access on
      Then the page opens without a tailnet name or Tailscale addresses
      And the other addresses are offered as usual

    # Legacy: packages/tailscale/src/tailscale.ts (ensureTailscaleServe servePort, DEFAULT_TAILSCALE_SERVE_PORT)
    @backlog @desktop
    Scenario Outline: The tailnet HTTPS address carries its port only when it is not the usual one
      Given Tailscale HTTPS is set up on port <port>
      When the user opens the Connections settings
      Then the tailnet HTTPS address is "<address>"

      Examples:
        | port | address                              |
        | 443  | https://laptop.tail1234.ts.net       |
        | 8443 | https://laptop.tail1234.ts.net:8443  |

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

    @backlog @desktop
    Scenario Outline: Network access says how this machine can be reached
      Given this machine is <state>
      When the user opens the Connections settings
      Then the network access row says "<description>"

      Examples:
        | state                                                              | description                                                         |
        | reachable on the network at https://192.168.1.4:3773               | Reachable at https://192.168.1.4:3773                               |
        | listening on all interfaces and advertising the host "desk.local"  | Exposed on all interfaces. Pairing links use desk.local.            |
        | listening on all interfaces with no address to advertise           | Exposed on all interfaces.                                          |
        | listening only on this machine                                     | Limited to this machine.                                            |
        | still reading its network state                                    | Loading…                                                            |

    @backlog @desktop
    Scenario: Several reachable addresses are folded behind the default one
      Given this machine is reachable at three addresses
      When the user opens the Connections settings
      Then the network access row names the default address and "+2"
      When the user opens the list of addresses
      Then every address is listed and the row offers to hide them again

    @backlog @desktop
    Scenario Outline: The confirmation names what a network access change does
      Given network access is <state>
      When the user changes network access
      Then the user is asked "<title>"
      And told "<effect>"
      And the button reads "<button>"

      Examples:
        | state | title                      | effect                                                                                                                                                                            | button              |
        | off   | Enable network access?     | Let your other devices connect to HAL-C2 over the network. Pair devices to give them access. HAL-C2 will restart.                                                                  | Restart and enable  |
        | on    | Disable network access?    | Devices connected over your local network will disconnect. Existing tunnels, such as HAL-C2 Connect or Tailscale HTTPS, keep working. HAL-C2 will restart.                         | Restart and disable |

    @backlog @desktop
    Scenario: Network access cannot be changed while the server restarts
      Given the user confirmed a network access change
      When the server is restarting
      Then the switch and the confirmation cannot be used
      And the confirmation cannot be dismissed until the restart finishes

    @backlog @desktop
    Scenario Outline: Network access is managed where the server starts when the app cannot restart it
      Given the app cannot restart this machine's server itself
      And the server is <exposure>
      When the user opens the Connections settings
      Then the network access row says "<description>"
      And its switch is shown but cannot be changed
      And hovering it says network exposure changes restart the server and are controlled where it is launched

      Examples:
        | exposure                   | description                                                                          |
        | already open to the network | Remote access is already configured. Change network exposure where the server starts. |
        | limited to this machine     | Only this machine can connect. Restart with a non-loopback host for remote pairing.   |

    @backlog @desktop
    Scenario Outline: The Tailscale HTTPS row says what is possible
      Given <state>
      When the user opens the Connections settings
      Then the Tailscale HTTPS row says "<description>"
      And its switch is <switch>

      Examples:
        | state                                    | description                                                                    | switch                   |
        | Tailscale is running and HTTPS is off    | Use Tailscale Serve to expose this backend through a MagicDNS HTTPS URL.       | off                      |
        | Tailscale is running and HTTPS is on     | https://desk.tail5e3a.ts.net                                                   | on                       |
        | Tailscale is not running                 | Start Tailscale to set up HTTPS access through MagicDNS.                       | not offered              |

    @backlog @desktop
    Scenario: Setting up Tailscale HTTPS shows where it will be served
      Given the user is setting up Tailscale HTTPS
      Then the user is asked "Set up Tailscale HTTPS?"
      And told HAL-C2 restarts the server with Tailscale Serve and asks Tailscale to proxy HTTPS traffic to it
      And the HTTPS endpoint it will use is shown, or "Pending MagicDNS endpoint" until it is known
      When the user enters a port outside 1 to 65535
      Then the user is told "Enter a port from 1 to 65535."
      And enabling is not available

    @backlog @desktop
    Scenario: Disabling Tailscale HTTPS names what stops
      Given Tailscale HTTPS is set up
      When the user turns it off
      Then the user is asked "Disable Tailscale HTTPS?"
      And told HAL-C2 restarts the server without Tailscale Serve
      And the button reads "Restart and disable"

    @backlog @desktop
    Scenario: Disabling Tailscale HTTPS that fails is reported
      Given Tailscale HTTPS is set up
      And the server cannot be restarted without it
      When the user turns off Tailscale HTTPS and confirms
      Then the user is told Tailscale HTTPS could not be disabled

    @backlog @desktop
    Scenario: A Tailscale HTTPS change cannot be interrupted
      Given the user confirmed setting up or disabling Tailscale HTTPS
      When the server is restarting
      Then the button reads "Restarting…"
      And cancelling and the switch cannot be used

    @backlog @desktop
    Scenario: WSL cannot be read
      Given the machine runs Windows and its WSL state cannot be read
      When the user opens the Connections settings
      Then the WSL row says "Couldn't load the WSL backend state."

    @backlog @desktop
    Scenario Outline: The WSL row appears only where WSL is in play
      Given the machine <state>
      When the user opens the Connections settings
      Then the WSL row is <shown>

      Examples:
        | state                                          | shown      |
        | has WSL available                              | shown      |
        | has WSL turned on although it is unavailable   | shown      |
        | has only WSL chosen although it is unavailable | shown      |
        | has WSL neither available nor in use           | not shown  |

    @backlog @desktop
    Scenario: Turning WSL on stages the choices before restarting once
      Given WSL is off
      When the user chooses the distribution "Debian" and "Use only WSL"
      Then only WSL and the distribution "Debian" are saved before WSL is turned on
      And HAL-C2 restarts once, on that selection

    @backlog @desktop
    Scenario: The WSL choices are Off and each distribution
      Given the machine runs Windows with the WSL distributions "Ubuntu" (the default) and "Debian"
      When the user opens the WSL choice
      Then the choices are "Off", "Ubuntu (default)" and "Debian"

    @backlog @desktop
    Scenario: With no distribution listed WSL offers its default
      Given the machine runs Windows with WSL installed but no distribution listed
      When the user opens the WSL choice
      Then the choices are "Off" and "Default distro"

    @backlog @desktop
    Scenario: WSL only is offered once WSL is on
      Given the WSL backend is on
      Then a "WSL only" choice says it runs only the WSL backend and restarts HAL-C2 when it changes
      When the WSL backend is off
      Then no "WSL only" choice is shown

    @backlog @desktop
    Scenario Outline: Each WSL change names what a restart does
      Given <state>
      When the user <action>
      Then the user is asked "<title>"
      And told "<effect>"
      And the button reads "<button>"

      Examples:
        | state                         | action                          | title                                           | effect                                                                                                                                                  | button              |
        | WSL runs beside Windows       | turns WSL off                   | Disable WSL backend?                            | The WSL backend will stop. Threads and projects opened against WSL stay safe inside the distro, but they'll be unavailable in HAL-C2 until you re-enable WSL. | Disable WSL         |
        | only WSL runs                 | turns WSL off                   | Turn off WSL and switch back to Windows?        | HAL-C2 will restart on the Windows backend. Threads and projects opened against WSL stay safe inside the distro and become available again when you re-enable WSL. | Switch to Windows   |
        | WSL runs beside Windows       | chooses another distribution    | Switch WSL distro?                              | HAL-C2 will restart the WSL backend on the new distro. Sessions still running on the current distro will be interrupted.                                | Switch distro       |
        | WSL runs beside Windows       | turns WSL only on               | Run only the WSL backend?                       | HAL-C2 will restart and start only the WSL backend. Your Windows-side projects won't be accessible until you turn this off again.                        | Restart and enable  |
        | only WSL runs                 | turns WSL only off              | Re-enable the Windows backend?                  | HAL-C2 will restart and bring the Windows backend back up alongside WSL.                                                                                | Restart and disable |

    @backlog @desktop
    Scenario: Turning WSL on asks whether Windows keeps running
      Given WSL is off
      When the user chooses a WSL distribution
      Then the user is asked "Start the WSL backend"
      And told to run the WSL backend alongside the Windows one or only WSL, and that this can be changed later
      And the choices are "Run both backends" and "Use only WSL"

    @backlog @desktop
    Scenario: A WSL change cannot be interrupted
      Given the user confirmed a WSL change
      When HAL-C2 is applying it
      Then the buttons read "Applying…" and nothing in the confirmation can be used

    @backlog @desktop
    Scenario: A WSL change that fails is reported
      Given HAL-C2 cannot apply a WSL change
      When the user confirms it
      Then the user is told the WSL backend could not be changed, with the reason

    @backlog @desktop
    Scenario: A WSL backend that could not start says why
      Given the WSL backend could not start because "the distro is not running"
      When the user opens the Connections settings
      Then the WSL row says "WSL backend couldn't start: the distro is not running"

    @backlog @desktop
    Scenario: A preference for WSL that is no longer available can be cleared
      Given the user chose WSL and WSL is no longer available, so Windows is running instead
      When the user opens the Connections settings
      Then the WSL row says "WSL is unavailable, so Windows is running instead. Turn WSL off to clear this preference."
      When the user turns WSL off and confirms
      Then the preference is cleared and HAL-C2 restarts on Windows

    @backlog @desktop
    Scenario: This machine's version line shows its address
      Given this machine runs server version 1.4.0 at "https://192.168.1.4:3773"
      When the user opens the Connections settings
      Then the version line reads "1.4.0 · https://192.168.1.4:3773"
      And while its version is still unknown it reads "Loading…"

    @backlog @desktop
    Scenario Outline: HAL-C2 Connect controls say why they cannot be used
      Given <state>
      When the user looks at the HAL-C2 Connect switches
      Then the switches cannot be changed
      And hovering them says "<reason>"

      Examples:
        | state                                                              | reason                                                                 |
        | the user is not signed in to HAL-C2 Connect                        | Sign in to HAL-C2 Connect to manage this environment.                  |
        | the user's session may not manage connectivity                     | Your session does not have permission to manage HAL-C2 Connect access. |

    @backlog @desktop
    Scenario Outline: Each HAL-C2 Connect change says what it did
      Given the user is signed in to HAL-C2 Connect
      And <state>
      When the user <action>
      Then the user is told "<title>"
      And "<detail>"

      Examples:
        | state                                | action                                | title                               | detail                                                              |
        | this machine is not linked           | links this machine                    | HAL-C2 Connect linked               | This environment is available through HAL-C2 Connect.               |
        | this machine is linked               | unlinks this machine                  | HAL-C2 Connect unlinked             | This environment is no longer available through HAL-C2 Connect.     |
        | agent activity is being published    | turns off the managed tunnel          | HAL-C2 Connect tunnel disabled      | The managed tunnel was removed. Agent activity publishing stays on. |
        | agent activity is not published      | turns on publishing agent activity    | Agent activity enabled              | This environment publishes agent activity to your mobile clients.   |
        | agent activity is published          | turns off publishing agent activity   | Agent activity disabled             | This environment will stop publishing agent activity.               |

    @backlog @desktop
    Scenario: Publishing agent activity does not need the link
      Given the user is signed in to HAL-C2 Connect
      And this machine is not linked
      When the user turns on publishing agent activity
      Then agent activity reaches mobile notifications and Live Activities without HAL-C2 Connect

  Rule: Authorized clients

    @backlog @desktop
    Scenario Outline: A pairing link starts from a preset of permissions
      When the user creates a pairing link and chooses the preset "<preset>"
      Then the permissions chosen are <permissions>

      Examples:
        | preset    | permissions                                                                            |
        | Read only | only viewing the environment                                                           |
        | Standard  | the standard set a paired client gets                                                  |

    @backlog @desktop
    Scenario Outline: Each permission is explained
      When the user creates a pairing link
      Then the permission "<permission>" says "<explanation>"

      Examples:
        | permission       | explanation                                           |
        | View environment | Read threads, status, diffs, and configuration.       |
        | Operate tasks    | Start tasks and perform changes in the environment.   |
        | Use terminals    | Create terminals and send input to running shells.    |
        | Write reviews    | Create comments while reviewing changes.              |
        | View access      | Inspect pairing links and authorized clients.         |
        | Manage access    | Issue and revoke credentials for other clients.       |
        | View relay       | Inspect managed relay connectivity.                   |
        | Manage relay     | Change managed tunnel connectivity.                   |

    @backlog @desktop
    Scenario: A pairing link that can manage access carries a warning
      When the user creates a pairing link that includes managing access
      Then the user is warned this client can create or revoke access for other devices

    @backlog @desktop
    Scenario: A pairing link's label is optional
      When the user creates a pairing link without a label
      Then the link is listed as "Pairing link"
      And the label field suggests a name such as "Living room iPad"

    @backlog @desktop
    Scenario: A pairing link cannot be created twice at once
      Given the user asked to create a pairing link
      When the server has not answered yet
      Then the button reads "Creating…" and cannot be used again

    @backlog @desktop
    Scenario: Closing the pairing link dialog forgets what was typed
      Given the user typed a label and changed the permissions
      When the user closes the dialog and opens it again
      Then the label is empty and the permissions are back to the standard set

    @backlog @desktop
    Scenario: A pairing link says when it expires and what it grants
      Given a pairing link that expires in 4 minutes with 3 permissions
      Then its row says it expires soon and shows "3 scopes"
      When the user hovers its expiry
      Then the exact expiry time is shown
      When the user opens its permissions
      Then each permission it grants is listed under "Granted scopes"

    @backlog @desktop
    Scenario: An expired pairing link is no longer listed
      Given a pairing link that expired a minute ago
      When the user opens the authorized clients
      Then the link is not listed

    @backlog @desktop
    Scenario: A pairing link with no address to share offers its code
      Given this machine has no address another device can reach
      When the user looks at a pairing link created here
      Then the row says to copy the token and pair from another client using this machine's reachable host
      And it offers to copy the code

    @backlog @desktop
    Scenario: A pairing link is shared by choosing how this machine is reached
      Given this machine can be reached over the local network and over Tailscale
      When the user chooses to share a pairing link
      Then the user is asked which address to reach this machine through
      And the link and its QR code follow the address chosen

    @backlog @desktop
    Scenario Outline: The share panel opens on the address most likely to work
      Given this machine can be reached at <addresses>
      And <preference>
      When the user chooses to share a pairing link
      Then the panel opens on <chosen>

      Examples:
        | addresses                                          | preference                             | chosen                       |
        | an address on this machine only and one on the local network | the user made the local network the default | the local network address    |
        | an address on this machine only and one on the local network | the user made no address the default        | the local network address    |
        | an address on this machine only                    | the user made no address the default   | that address, without a QR code |
        | one address that is currently unavailable          | the user made no address the default   | no QR code                   |

    @backlog @desktop
    Scenario: An address that is gone is replaced by a working one
      Given the user chose to share a pairing link through an address
      When that address stops being offered
      Then the panel moves to the default address, or to the first address that can be shared

    @backlog @desktop
    Scenario: A machine reached one way offers no choice of address
      Given this machine can be reached only one way
      When the user chooses to share a pairing link
      Then no choice of address is shown

    @backlog @desktop
    Scenario: A shared pairing link can be copied whole or as its code only
      Given the user is sharing a pairing link
      When the user copies the link
      Then the whole link is on the clipboard
      When the user copies the code only
      Then just the pairing code is on the clipboard

    @backlog @desktop
    Scenario Outline: A client says whether it is connected
      Given the client "Phone" is <state>
      When the user hovers its status
      Then it says "<status>"

      Examples:
        | state                                           | status                          |
        | connected and has been for 2 hours              | Connected for 2 hours           |
        | connected with no known start                   | Connected                       |
        | not connected but was last connected at 09:12   | Last connected at 09:12         |
        | paired and never connected                      | Not connected yet               |

    @backlog @desktop
    Scenario: A client is named by its label or by what it runs on
      Given a client with no label that runs on "Android" in "Chrome"
      Then it is listed as "Android · Chrome"
      And its row shows its device type, system, browser and address when known

    @backlog @desktop
    Scenario: The desktop app presents itself by name, system and version when it pairs
      Given the desktop app runs on Linux at a released version
      When it pairs with an environment
      Then the environment lists it as "HAL-C2 Desktop" on a desktop running Linux
      And the listing includes the app's version

    @backlog @desktop
    Scenario: This device is marked and cannot be revoked from itself
      Given this client is listed with other clients
      Then this client is marked "This device"
      And it is listed first
      And it has no revoke action

    @backlog @desktop
    Scenario: Connected clients are listed before others, newest first
      Given the clients "Old laptop" (not connected, paired first), "Phone" (connected) and "Tablet" (not connected, paired last)
      When the user opens the authorized clients
      Then the order is this device, "Phone", "Tablet", "Old laptop"

    @backlog @desktop
    Scenario: Revoking a client cannot be repeated while it is under way
      Given the user asked to revoke "Phone"
      When the server has not answered yet
      Then the action reads "Revoking…" and cannot be used again

    @backlog @desktop
    Scenario: Revoking the other clients needs another client
      Given only this client is listed
      Then revoking the others is not available

    @backlog @desktop
    Scenario Outline: Revoking the others says how many were revoked
      Given <count> other clients are listed
      When the user revokes the others
      Then the user is told "<title>"
      And "Other paired clients will need a new pairing link before reconnecting."

      Examples:
        | count | title                 |
        | 1     | Revoked 1 other client |
        | 3     | Revoked 3 clients      |

    @backlog @desktop
    Scenario Outline: A revoke that fails is reported
      Given the server refuses to <action>
      When the user does so
      Then the user is told "<title>"

      Examples:
        | action                          | title                              |
        | revoke a pairing link           | Could not revoke pairing link      |
        | revoke a client                 | Could not revoke client access     |
        | revoke the other clients        | Could not revoke other clients     |

    @backlog @desktop
    Scenario Outline: The authorized clients are summarised while folded
      Given <clients> clients and <links> pairing links are listed
      When the authorized clients are folded
      Then the summary reads "<summary>"

      Examples:
        | clients | links | summary                      |
        | 1       | 0     | 1 client                     |
        | 3       | 0     | 3 clients                    |
        | 2       | 1     | 2 clients · 1 pairing link   |
        | 2       | 4     | 2 clients · 4 pairing links  |

    @backlog @desktop
    Scenario: Authorized clients are managed only where other devices can reach this machine
      Given this machine is limited to itself
      When the user opens the Connections settings
      Then the authorized clients are not listed
      When network access is turned on
      Then the authorized clients are listed

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

    # A link names the address its machine says it is reached at (the MC's
    # hal-c2.createPairingLink, connections/pairing.feature), and the QR code holds exactly
    # the link shown: the phone app scans it, and a phone's own camera opens it as a page of
    # that machine.
    @desktop
    Scenario: A pairing link can be shared as a QR code except on this machine's own address
      Given this machine is reached over Tailscale at "https://desk.tail5e3a.ts.net"
      When the user creates a pairing link over Tailscale
      Then the link shown starts with "https://desk.tail5e3a.ts.net/pair#token="
      And a QR code of the link shown is offered, dark on light
      When the user creates a pairing link at the address this machine listens on
      Then no QR code is offered
      And the user is told to create the link over Tailscale or start the machine on a network address

    @desktop
    Scenario Outline: The QR code of a pairing link keeps a size a phone can scan
      Given this machine is reached over Tailscale at "https://desk.tail5e3a.ts.net"
      And the Connections settings are shown in <window>
      When the user creates a pairing link over Tailscale
      Then the QR code of the link shown is <drawn>

      Examples:
        | window                                    | drawn                               |
        | a wide window                             | whole, at its full size             |
        | a narrow window                           | whole, smaller                      |
        | a window narrower than a code can be read | no smaller than a phone can scan    |

    @desktop
    Scenario: Tailscale that cannot publish the machine leaves no pairing link
      Given Tailscale is not running on this machine
      When the user creates a pairing link over Tailscale
      Then the user is told the pairing URL could not be created
      And no pairing link is shown

    # A phone paired with the laptop its user sits at stops working when the laptop sleeps:
    # the link can be for a machine of the cluster that stays on.
    @desktop
    Scenario: A pairing link can be for another machine of the cluster
      Given the cluster also has the machine "Studio", reached over Tailscale at "https://studio.tail5e3a.ts.net"
      When the user creates a pairing link for "Studio" over Tailscale
      Then "Studio" is asked for the pairing link over Tailscale
      And the link shown starts with "https://studio.tail5e3a.ts.net/pair#token="
      And a QR code of the link shown is offered, dark on light

    @desktop
    Scenario: A pairing link is for this machine until the user chooses another
      Given the cluster also has the machine "Studio", reached over Tailscale at "https://studio.tail5e3a.ts.net"
      And this machine is reached over Tailscale at "https://desk.tail5e3a.ts.net"
      When the user creates a pairing link over Tailscale
      Then this machine is asked for the pairing link over Tailscale
      And the link shown starts with "https://desk.tail5e3a.ts.net/pair#token="

    @desktop
    Scenario: Only machines that are online are offered for a pairing link
      Given the cluster also has the machines "Studio" and "Laptop"
      When "Laptop" becomes unreachable
      Then a pairing link can be for this machine or "Studio"
      When "Laptop" is reachable again
      Then a pairing link can be for this machine, "Laptop" or "Studio"

    @desktop
    Scenario: A machine on its own offers no choice of machine for a pairing link
      Then no choice of machine is offered for a pairing link

    # The list is of this machine's links, so one made on another machine is revoked where
    # it is shown.
    @desktop
    Scenario: A pairing link made on another machine is revoked there
      Given the cluster also has the machine "Studio"
      And the user created a pairing link for "Studio"
      When the user revokes that link
      Then "Studio" is asked to revoke it
      And no pairing link is shown
      And a device can no longer pair with it

    # An MC from before pairing links named their address.
    @desktop
    Scenario: A machine that does not say where it is reached is paired at the address this desktop reached it at
      Given this machine runs a HAL-C2 from before pairing links named their address
      When the user creates a pairing link at the address this machine listens on
      Then the link shown starts with the address this desktop reached the machine at

    @desktop
    Scenario: Another machine that does not say where it is reached gets no pairing link
      Given the cluster also has the machine "Studio"
      And "Studio" runs a HAL-C2 from before pairing links named their address
      When the user creates a pairing link for "Studio"
      Then the user is told the pairing URL could not be created
      And no pairing link is shown
      And a device can no longer pair with it

    # A link's secret is shown only while the page that asked for it stays open. One that
    # arrives after the user left can be used by nobody, on that visit or the next, and for
    # another machine it is not in this machine's list either: its machine takes it back.
    @desktop
    Scenario Outline: A pairing link that arrives after the user left the page is revoked, not shown
      Given the cluster also has the machine "Studio"
      And the MC holds its answers
      When the user asks for a pairing link for "Studio"
      And the user leaves the Connections page
      And <first>
      And <then>
      Then no pairing link is shown
      And "Studio" is asked to revoke it
      And a device can no longer pair with it

      Examples:
        | first                                       | then                                        |
        | the MC answers                              | the user comes back to the Connections page |
        | the user comes back to the Connections page | the MC answers                              |

    # A device paired with another machine of the cluster is that machine's client, and
    # the MC answers the access list and client revocation only for the machine the session
    # is on (hal-c2.clients and hal-c2.revokeClient refuse with "session_on_another_mc").
    # Waits for the maintainers: whether a session on one member may manage another's clients.
    @backlog @blocked @desktop
    Scenario: A device paired with another machine of the cluster is listed and revoked from here
      Given the cluster also has the machine "Studio"
      And the phone "Pixel" paired with "Studio" through a link created here
      When the user looks at who may reach "Studio"
      Then "Pixel" is listed
      When the user revokes "Pixel"
      Then "Pixel" can no longer reach "Studio"

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

    @backlog @desktop
    Scenario: With no other environments the list says how to add one
      Given no other environment is saved
      When the user opens the environments
      Then the user is told there are no saved remote environments
      And told how to add one, or to connect one from HAL-C2 Connect when signed in there

    @backlog @desktop
    Scenario: An environment this device has not reached yet says so
      Given "Build box" is saved and this device has not tried to connect to it
      Then its row reads "Not connected"

    @backlog @desktop
    Scenario Outline: An environment says what it is running and doing in one line
      Given "Build box" is reached <route>
      And it is <state>
      Then its row reads "<line>"

      Examples:
        | route                    | state                                         | line                                  |
        | over SSH as ada@devbox   | connected                                     | SSH ada@devbox · Connected            |
        | through WSL              | switched off                                  | WSL · Off                             |
        | through HAL-C2 Connect   | connected and behind this client at 1.3.0     | HAL-C2 Connect · Connected · 1.3.0    |
        | through HAL-C2 Connect   | restarting to finish an update                | HAL-C2 Connect · Restarting           |

    @backlog @desktop
    Scenario: Hovering an environment's status gives the long form
      Given "Build box" is reconnecting after a timeout and behind this client
      When the user hovers its status
      Then the full connection sentence is shown
      And the version it would update from and to is shown

    @backlog @desktop
    Scenario: An environment that is switched off says so on hover
      Given "Build box" is switched off
      When the user hovers its status
      Then it says "Switched off"

    @backlog @desktop
    Scenario: An environment this client cannot talk to cannot be switched on
      Given "Build box" runs a version this client does not support
      Then its row reads "Client not supported"
      And its switch cannot be changed and says "Client not supported"

    @backlog @desktop
    Scenario: Only a connected, switched-on environment offers its update
      Given "Build box" runs an older server than this client
      When "Build box" is switched off
      Then its row offers no update
      When "Build box" is switched on but cannot be reached
      Then its row offers no update
      When "Build box" is connected
      Then its row offers an update to this client's version

    @backlog @desktop
    Scenario: A failed update of an environment can be retried
      Given the last update of "Build box" failed
      Then its update action reads "Retry update"

    @backlog @desktop
    Scenario: An environment mid-update shows its progress and offers no second update
      Given "Build box" is being updated
      Then its row shows the progress of the update
      And no update action is offered for it

    @backlog @desktop
    Scenario: Updating every outdated environment skips those that cannot take it
      Given "Build box" is connected and outdated, "Laptop" is switched off and outdated, "Studio" is outdated but is updated by hand, and "Pi" is mid-update
      When the user looks at the environments
      Then the update-all action is offered
      And it would update only "Build box"

    @backlog @desktop
    Scenario: Nothing outdated offers no update-all action
      Given every environment is up to date
      Then no update-all action is offered

    @backlog @desktop
    Scenario: A trace ID is offered only when there is one
      Given "Build box" failed to connect with the trace ID "ab12cd"
      When the user opens the actions of "Build box"
      Then copying its trace ID is offered
      When the user copies it
      Then the user is told "Trace ID copied" with the ID
      Given "Studio" is connected
      Then copying a trace ID is not offered for "Studio"

    @backlog @desktop
    Scenario: A trace ID that cannot be copied is reported
      Given the clipboard is unavailable
      When the user copies the trace ID of "Build box"
      Then the user is told the trace ID could not be copied, with the reason

    @backlog @desktop
    Scenario: The WSL backend has no row of its own in the Connections settings
      Given the WSL backend is running beside Windows
      When the user looks at the environments in the Connections settings
      Then the WSL backend has no row of its own there
      And it is managed from the WSL row under this machine
      But it is still one of the app's environments and can take threads

    @backlog @desktop
    Scenario: An environment found through HAL-C2 Connect is listed with its detected machine icon
      Given "Build box" was found through HAL-C2 Connect and this device has never reached it
      When the user looks at the environments
      Then "Build box" is shown with the icon of the kind of machine it is
      And the icon stays the same while the list refreshes

    @backlog @desktop
    Scenario: Adding an environment over SSH needs a host
      Given the user is adding an environment over SSH
      When the user adds it with no host
      Then the user is told "SSH host or alias is required."
      And nothing is connected

    @backlog @desktop
    Scenario Outline: An SSH address is read into host, user and port
      Given the user is adding an environment over SSH
      When the user enters "<host>" with the username field "<username>" and the port field "<port>"
      Then HAL-C2 connects to "<hostname>" as "<user>" on port "<effective port>"

      Examples:
        | host              | username | port | hostname  | user  | effective port |
        | devbox            |          |      | devbox    | none  | the default    |
        | ada@devbox        |          |      | devbox    | ada   | the default    |
        | ada@devbox:2222   |          |      | devbox    | ada   | 2222           |
        | [fe80::1]:2222    |          |      | fe80::1   | none  | 2222           |
        | ada@devbox        | root     |      | devbox    | root  | the default    |
        | devbox:2222       |          | 2200 | devbox    | none  | 2200           |

    @backlog @desktop
    Scenario Outline: An SSH port must be a real port
      Given the user is adding an environment over SSH
      When the user enters the port "<port>"
      Then the user is told "SSH port must be between 1 and 65535."

      Examples:
        | port  |
        | 0     |
        | 65536 |

    @backlog @desktop
    Scenario: An SSH environment that connects is reported
      Given the user is adding an environment over SSH to "devbox"
      When the connection succeeds
      Then the user is told "Environment connected" and that "devbox" is ready over an SSH-managed tunnel
      And the dialog closes and its fields are empty the next time

    @backlog @desktop
    Scenario: An SSH environment that fails to connect shows the reason in the dialog
      Given the connection to "devbox" fails with "Permission denied (publickey)."
      When the user adds it
      Then the dialog shows "Permission denied (publickey)."
      And the user can correct the fields and try again
      And a failure with no reason reads "Failed to connect SSH host."

    @backlog @desktop
    Scenario: Hosts from the user's SSH config are suggested
      Given the user's SSH config names the hosts "devbox" and "buildbox"
      When the user opens the SSH host field
      Then both hosts are suggested with their address when it differs from the alias
      And the config is read again each time the dialog opens

    # Legacy: packages/ssh/src/config.ts (collectSshConfigAliasesFromFile, expandGlob)
    @backlog @desktop
    Scenario: Hosts from files the SSH config includes are suggested
      Given the user's SSH config includes another file that names the host "buildbox"
      When the user opens the SSH host field
      Then "buildbox" is suggested

    # Legacy: packages/ssh/src/config.ts (hasSshPattern)
    @backlog @desktop
    Scenario: SSH config patterns are not suggested as hosts
      Given the user's SSH config has a host entry "*.internal" and another that excludes "!staging"
      When the user opens the SSH host field
      Then neither "*.internal" nor "!staging" is suggested

    # Legacy: packages/ssh/src/config.ts (parseKnownHostsHostnames, normalizeKnownHostsHostname)
    @backlog @desktop
    Scenario: Hosts the user has connected to before are suggested
      Given the user's known hosts file lists "box.example,10.0.0.7" and "[gate.example]:2222"
      When the user opens the SSH host field
      Then "box.example", "10.0.0.7" and "gate.example" are suggested
      And hosts whose names are hashed in the file are not suggested
      And host patterns in the file are not suggested

    @backlog @desktop
    Scenario: Typing narrows the suggested SSH hosts
      Given the user's SSH config names the hosts "devbox" and "buildbox"
      When the user types "dev"
      Then only "devbox" is suggested
      When the user types "zzz"
      Then the user is told no hosts match "zzz"

    # Legacy: apps/web/src/state/desktopSshHosts.ts (filterDiscoveredSshHosts)
    @backlog @desktop
    Scenario: SSH hosts that start with what the user typed come before hosts that only contain it
      Given the user's SSH config names the hosts "web-dev", "devbox" and "old-dev"
      When the user types "dev"
      Then "devbox" is suggested first
      And "web-dev" and "old-dev" follow in the order of the SSH config

    @backlog @desktop
    Scenario: Suggested SSH hosts are matched without regard to case or surrounding spaces
      Given the user's SSH config names the host "DevBox"
      When the user types " dev "
      Then "DevBox" is suggested

    @backlog @desktop
    Scenario: An SSH host that is already an environment is not suggested again
      Given "devbox" is already an environment over SSH
      When the user opens the SSH host field
      Then "devbox" is not suggested

    @backlog @desktop
    Scenario: Choosing a suggested SSH host connects it
      Given the user's SSH config names the host "devbox" with a user and a port
      When the user chooses "devbox" from the suggestions
      Then the user and port from the config fill in the fields
      And HAL-C2 connects to "devbox" at once

    @backlog @desktop
    Scenario: Adding an environment over SSH cannot be repeated while it connects
      Given the user asked to add an environment over SSH
      When it has not connected yet
      Then the button reads "Adding…"
      And the fields and the button cannot be used

    @backlog @desktop
    Scenario: Enter adds the SSH host unless a suggestion is highlighted
      Given the user typed an SSH host
      When the user presses Enter with no suggestion highlighted
      Then the environment is added
      When a suggestion is highlighted and the user presses Enter
      Then that suggestion is chosen instead
