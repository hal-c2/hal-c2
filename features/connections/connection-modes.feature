# Sources:
#   docs/user/remote-access.md (Pair over a LAN or private network, Tailscale HTTPS, Hosted web app,
#     Desktop-managed SSH)
#   docs/internals/remote.md
#   packages/contracts/src/remoteAccess.ts (advertised endpoint kinds, reachability, hosted HTTPS compatibility)
#   apps/server-ex/lib/t3/web.ex (listener on loopback by default)
#   apps/server-ex/lib/t3/cluster/tailscale.ex (tailnet discovery for cluster members)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (Network access, Tailscale HTTPS,
#     "Only this machine can connect. Restart with a non-loopback host for remote pairing.")
#   apps/web/src/components/settings/EnvironmentRow.tsx (SshConnectionTarget, SshConnectionProfile)
#   apps/desktop-qt/parity/features.backlog.test.ts (ssh-environments, network-access)
#   apps/tui/src/features.backlog.test.ts (environment-connections)
#   Shared domain: node/platform/node-startup.feature holds the node's own listening address;
#   connections/cluster.feature holds nodes reaching each other over the tailnet;
#   connections/t3-connect.feature holds the relay;
#   settings/connections.feature holds the desktop network access, Tailscale HTTPS and add-over-SSH controls.

Feature: How clients reach an environment
  A node listens on loopback unless told otherwise. Clients reach it directly on a LAN or
  tailnet, over Tailscale HTTPS, through a desktop-managed SSH forward, or through T3 Connect.

  Background:
    Given a running node

  @node
  Scenario: A node reaches only its own machine by default
    When a client on another machine tries to connect
    Then the connection is refused

  @node
  Scenario: A client on the same machine connects over loopback
    When a client on the node's machine connects to the loopback address
    Then it reaches the node

  @backlog @node
  Scenario: An operator starts a node that listens on its LAN address
    When an operator starts the node with a LAN host
    Then clients on the LAN can pair with it

  @backlog @desktop
  Scenario: A loopback-only node explains how to allow remote pairing
    Given network access is off
    When the user opens Connections settings
    Then the client says only this machine can connect

  @backlog @desktop
  Scenario Outline: Advertised addresses say who can reach them
    Given the node advertises a <reachability> address
    When the user chooses an address for a pairing link
    Then the address is marked as reachable from <who>

    Examples:
      | reachability    | who                             |
      | loopback        | this machine only               |
      | lan             | the local network               |
      | private-network | the private network or tailnet  |
      | public          | anywhere                        |

  @backlog @desktop
  Scenario Outline: Advertised addresses say whether a hosted HTTPS client can use them
    Given the node advertises an address whose hosted HTTPS compatibility is <compatibility>
    When the user chooses an address for a pairing link
    Then the client <advice>

    Examples:
      | compatibility          | advice                                                    |
      | compatible             | offers it for HTTPS clients                               |
      | mixed-content-blocked  | warns that an HTTPS client cannot reach a plain HTTP link |
      | requires-configuration | says the address needs HTTPS set up first                 |
      | unknown                | offers it without a promise                               |

  @backlog @desktop
  Scenario: Turning off network access keeps tunnels working
    Given network access is on
    And the environment is also reachable through T3 Connect and Tailscale HTTPS
    When the user turns network access off
    Then devices on the local network disconnect
    And the tunnels keep working

  @backlog @desktop
  Scenario: Tailscale HTTPS without Tailscale explains itself
    Given Tailscale is not running on this machine
    When the user turns on Tailscale HTTPS
    Then the client says to start Tailscale to set up HTTPS through MagicDNS

  @backlog @node
  Scenario: An operator pairs over Tailscale HTTPS from the command line
    Given the node's machine is on a tailnet
    When an operator asks for a Tailscale pairing link
    Then the node is served at its tailnet HTTPS name
    And the printed link uses that name

  @backlog @node
  Scenario: The Tailscale route survives a restart
    Given an operator created a Tailscale pairing link
    When the node restarts
    Then the tailnet HTTPS name still reaches it

  @backlog @node
  Scenario: A taken Tailscale port can be replaced
    Given the default tailnet HTTPS port is in use
    When an operator asks for a Tailscale pairing link on another port
    Then the link uses that port

  @backlog @desktop
  Scenario: The first SSH launch installs the server on the host
    Given a host that has never run T3 Code
    When the user adds it as an SSH environment
    Then the server is downloaded to the host's runtime folder before it starts

  @backlog @desktop
  Scenario: An SSH host that asks for a password
    Given an SSH host that needs a password
    When the desktop app connects
    Then the user is asked for the password
    And the password is not kept after the connection

  @backlog @desktop
  Scenario: A saved SSH environment reconnects without pairing again
    Given a saved SSH environment
    When the desktop app restarts
    Then it reconnects over SSH without a new pairing link

  @backlog @desktop
  Scenario: An SSH host that cannot run the server explains why
    Given an SSH host that is not Linux or an Apple Silicon Mac
    When the user adds it as an SSH environment
    Then the client says the host is not supported

  @backlog @desktop
  Scenario: Removing an SSH environment stops only a server the app launched
    Given an SSH environment whose server the desktop app launched
    When the user removes it
    Then that server stops

  @backlog @desktop
  Scenario: Removing an SSH environment leaves a server that was already running
    Given an SSH environment that reused a running server
    When the user removes it
    Then that server keeps running

  @backlog @desktop
  Scenario: A failed SSH reconnect after an update can be retried
    Given an SSH environment fails to reconnect after an app update
    When the user retries the launch
    Then the environment reconnects

  # The hosted app at app.t3.codes connects to a node over HTTPS. hal-c2 has no hosted web
  # client; QML clients connect over plain HTTP on a LAN or tailnet.
  @dropped @node
  Scenario: A hosted HTTPS client connects only to HTTPS environments
    Given the environment offers only a plain HTTP address
    When the hosted app tries to connect
    Then the browser blocks the connection
