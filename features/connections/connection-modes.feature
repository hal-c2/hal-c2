# Sources:
#   docs/user/remote-access.md (Pair over a LAN or private network, Tailscale HTTPS, Hosted web app,
#     Desktop-managed SSH)
#   docs/internals/remote.md
#   packages/contracts/src/remoteAccess.ts (advertised endpoint kinds, reachability, hosted HTTPS compatibility)
#   apps/server-ex/lib/hal_c2/web.ex (listener on loopback by default)
#   apps/server-ex/lib/hal_c2/cluster/tailscale.ex (tailnet discovery for cluster members)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (Network access, Tailscale HTTPS,
#     "Only this machine can connect. Restart with a non-loopback host for remote pairing.")
#   apps/web/src/components/settings/EnvironmentRow.tsx (SshConnectionTarget, SshConnectionProfile)
#   apps/desktop-qt/parity/features.backlog.test.ts (ssh-environments, network-access)
#   apps/web/src/components/desktop/SshPasswordPromptDialog.tsx (the password prompt)
#   apps/web/src/connection/platform.ts (SSH provisioning, secondary backends)
#   apps/tui/src/features.backlog.test.ts (environment-connections)
#   apps/server/src/cli/sshHelper.ts (the remote half of an SSH launch: reuse a live loopback server,
#     pick a free port from the last one used, wait until the server answers)
#   apps/desktop/src/main.ts (the SSH host runs the release the app is on, from a self-contained archive)
#   packages/ssh/src/tunnel.ts, command.ts (launch script: install, checksum, lock, reuse, log tail, stop;
#     password retries; target resolution; error redaction)
#   Shared domain: mc/platform/mc-startup.feature holds the MC's own listening address;
#   connections/cluster.feature holds MCs reaching each other over the tailnet;
#   connections/hal-c2-connect.feature holds the relay;
#   settings/connections.feature holds the desktop network access, Tailscale HTTPS and add-over-SSH controls.

Feature: How clients reach an environment
  An MC listens on loopback unless told otherwise. Clients reach it directly on a LAN or
  tailnet, over Tailscale HTTPS, through a desktop-managed SSH forward, or through HAL-C2 Connect.

  Background:
    Given a running MC

  @mc
  Scenario: An MC reaches only its own machine by default
    When a client on another machine tries to connect
    Then the connection is refused

  @mc
  Scenario: A client on the same machine connects over loopback
    When a client on the MC's machine connects to the loopback address
    Then it reaches the MC

  @mc
  Scenario: An operator starts an MC that listens on its LAN address
    When an operator starts the MC with a LAN host
    Then clients on the LAN can pair with it

  @backlog @desktop
  Scenario: A loopback-only MC explains how to allow remote pairing
    Given network access is off
    When the user opens Connections settings
    Then the client says only this machine can connect

  @backlog @desktop
  Scenario Outline: Advertised addresses say who can reach them
    Given the MC advertises a <reachability> address
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
    Given the MC advertises an address whose hosted HTTPS compatibility is <compatibility>
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
    And the environment is also reachable through HAL-C2 Connect and Tailscale HTTPS
    When the user turns network access off
    Then devices on the local network disconnect
    And the tunnels keep working

  @backlog @desktop
  Scenario: Tailscale HTTPS without Tailscale explains itself
    Given Tailscale is not running on this machine
    When the user turns on Tailscale HTTPS
    Then the client says to start Tailscale to set up HTTPS through MagicDNS

  @mc
  Scenario: An operator pairs over Tailscale HTTPS from the command line
    Given the MC's machine is on a tailnet
    When an operator asks for a Tailscale pairing link
    Then the MC is served at its tailnet HTTPS name
    And the printed link uses that name

  @mc
  Scenario: The Tailscale route survives a restart
    Given an operator created a Tailscale pairing link
    When the MC restarts
    Then the tailnet HTTPS name still reaches it

  @mc
  Scenario: A taken Tailscale port can be replaced
    Given the default tailnet HTTPS port is in use
    When an operator asks for a Tailscale pairing link on another port
    Then the link uses that port

  @backlog @desktop
  Scenario: The first SSH launch installs the server on the host
    Given a host that has never run HAL-C2
    When the user adds it as an SSH environment
    Then the server is downloaded to the host's runtime folder before it starts

  # Legacy: apps/desktop/src/main.ts (resolveDesktopSshCliRunner: the release the app is on, no Node on the host)
  @backlog @desktop
  Scenario: An SSH host runs the same release as the desktop app
    Given the desktop app is version "1.4.0"
    And a host that has never run HAL-C2
    When the user adds it as an SSH environment
    Then the host runs version "1.4.0" of the server
    And the host needs neither Node nor a compiler for it

  @backlog @desktop
  Scenario: After an app update an SSH host is launched on the new release
    Given an SSH environment whose host last ran version "1.3.0"
    And the desktop app is now version "1.4.0"
    When the app reconnects to the environment
    Then the host runs version "1.4.0" of the server

  @backlog @desktop
  Scenario: An SSH launch reuses a server already running on the host
    Given the host already runs a HAL-C2 server for its own user on its loopback address
    When the user adds it as an SSH environment
    Then the desktop app connects to that server
    And no second server is started on the host

  @backlog @desktop
  Scenario: An SSH launch ignores a runtime record whose server has gone
    Given the host's runtime record names a server that is no longer running
    When the user adds it as an SSH environment
    Then a new server is started on the host

  @backlog @desktop
  Scenario: An SSH launch keeps the port the host used last when it is free
    Given the host's server last ran on a port that is free
    When the user connects to the SSH environment
    Then the server starts on that port

  @backlog @desktop
  Scenario: An SSH launch takes the next free port when the usual one is taken
    Given the port the host's server used last is taken by another program
    When the user connects to the SSH environment
    Then the server starts on the next free port after it

  @backlog @desktop
  Scenario: An SSH launch fails when no port is free in the range it tries
    Given every port in the range the launch tries is taken
    When the user connects to the SSH environment
    Then the connection fails saying no port was available on the host

  @backlog @desktop
  Scenario: An SSH launch fails when the server never answers
    Given the server on the host starts but does not answer its health check in time
    When the user connects to the SSH environment
    Then the connection fails saying the server did not become ready

  @backlog @desktop
  Scenario: An SSH host that asks for a password
    Given an SSH host that needs a password
    When the desktop app connects
    Then the user is asked for the password
    And the password is not kept after the connection

  @backlog @desktop
  Scenario: The password prompt names the host and the user it is for
    Given an SSH host that needs a password for "olafur@build-box"
    When the desktop app connects
    Then the prompt names "olafur@build-box"
    And it says the password is used for this connection attempt only and is not saved

  @backlog @desktop
  Scenario: A password prompt that was not answered in time expires
    Given the password prompt for an SSH host is showing a countdown
    When the time runs out
    Then the prompt says it expired and cannot be answered
    And the user is told to try connecting again

  @backlog @desktop
  Scenario: Cancelling the password prompt stops the connection without retrying
    Given an SSH host that needs a password
    When the user cancels the password prompt
    Then the connection stops
    And it is not retried until the user connects again

  @backlog @desktop
  Scenario: Several hosts asking for a password are asked one at a time
    Given two SSH hosts that each need a password
    When the desktop app connects to both
    Then the user is asked for the first host's password
    And the second host's prompt follows once the first is answered or cancelled

  # Legacy: apps/desktop/src/ssh/DesktopSshPasswordPrompts.ts
  @backlog @desktop
  Scenario: The password prompt comes to the front of a minimized window
    Given an SSH host that needs a password
    And the app's window is minimized
    When the desktop app connects
    Then the window is restored and brought forward
    And the user is asked for the password

  @backlog @desktop
  Scenario: Closing the window cancels a waiting password prompt
    Given the user is being asked for an SSH host's password
    When the user closes the app's window
    Then the connection fails saying the authentication was cancelled because the window closed

  @backlog @desktop
  Scenario: A password cannot be asked for when there is no window
    Given an SSH host that needs a password
    And the app has no window open
    When the desktop app connects
    Then the connection fails saying no window is available for SSH authentication

  @backlog @desktop
  Scenario: An SSH environment is only offered on the desktop app
    When a client that is not the desktop app tries to add an SSH environment
    Then it is told that SSH environments are only available in the desktop app

  @backlog @desktop
  Scenario: An SSH host whose server cannot be described is not paired
    Given an SSH host whose server started but cannot describe itself
    When the desktop app connects
    Then the connection fails and can be retried
    And the one-time pairing credential is not consumed

  @backlog @desktop
  Scenario: A saved SSH environment reconnects without pairing again
    Given a saved SSH environment
    When the desktop app restarts
    Then it reconnects over SSH without a new pairing link

  # Legacy: apps/desktop/src/ipc/methods/sshEnvironment.ts (DesktopSshEnvironmentRequestError)
  @backlog @desktop
  Scenario Outline: A request to an SSH host's server that is refused says what the server answered
    Given a saved SSH environment whose server answers with <status>
    When the desktop app asks it to <operation>
    Then the failure names the operation and the status the server gave

    Examples:
      | status                      | operation          |
      | not authorized              | describe itself    |
      | forbidden                   | issue a credential |
      | an internal error           | describe itself    |

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

  # Legacy: packages/ssh/src/tunnel.ts (handleSshAuthFailure: promptCount >= 2)
  @backlog @desktop
  Scenario: A wrong SSH password is asked for once more and then the connection fails
    Given an SSH host that needs a password
    When the user enters a wrong password
    Then the user is asked for the password again
    When the user enters a wrong password a second time
    Then the connection fails with the host's authentication error
    And the user is not asked a third time

  # Legacy: packages/ssh/src/tunnel.ts (the runner script: Checksum mismatch)
  @backlog @desktop
  Scenario: A server download that does not match its published checksum is not installed on the host
    Given a host that has never run HAL-C2
    And the download of the server on it does not match the checksum published for the release
    When the user adds it as an SSH environment
    Then the connection fails saying the checksum does not match
    And the host is left without that server install

  # Legacy: packages/ssh/src/tunnel.ts (the runner script: executable does not run on this host)
  @backlog @desktop
  Scenario: A downloaded server that cannot run on the host is not kept for later launches
    Given a host that has never run HAL-C2
    And the downloaded server cannot run on that host
    When the user adds it as an SSH environment
    Then the connection fails saying the server does not run on the host
    And the next connection downloads and checks it again

  # Legacy: packages/ssh/src/tunnel.ts (hal_c2_fetch: curl or wget)
  @backlog @desktop
  Scenario: A host that can download neither with curl nor with wget says what it needs
    Given a host that has never run HAL-C2 and has neither curl nor wget
    When the user adds it as an SSH environment
    Then the connection fails saying the host needs curl or wget to download the server

  # Legacy: packages/ssh/src/tunnel.ts (REMOTE_RUNNER_SCRIPT install lock)
  @backlog @desktop
  Scenario: Two launches onto one host install the server once
    Given a host that has never run HAL-C2
    And two environments reach that host as the same user
    When both are connected at once
    Then the server is downloaded and installed once
    And both launches use that install

  # Legacy: packages/ssh/src/tunnel.ts (REMOTE_LAUNCH_SCRIPT: tail -n 80 "$LOG_FILE")
  @backlog @desktop
  Scenario: A server that fails to start on the host shows the end of its log
    Given the server started on the host exits before it answers
    When the user connects to the SSH environment
    Then the connection fails with the last lines the server wrote
    And the failed start leaves nothing running or recorded on the host

  # Legacy: packages/ssh/src/tunnel.ts (REMOTE_LAUNCH_SCRIPT: wrote nothing)
  @backlog @desktop
  Scenario: A server that fails to start without writing anything says so
    Given the server started on the host exits before writing any output
    When the user connects to the SSH environment
    Then the connection fails saying the server exited before producing any output

  # Legacy: packages/ssh/src/tunnel.ts (REMOTE_LAUNCH_SCRIPT: DEFAULT_RUNTIME_FILE, managed -> external)
  @backlog @desktop
  Scenario: A server the user starts on the host themselves replaces the one the app launched
    Given the app launched a server on the host for an SSH environment
    And the user then starts their own HAL-C2 server on that host
    When the user connects to the SSH environment
    Then the app's launched server stops
    And the environment connects to the user's own server
    And removing the environment leaves that server running

  # Legacy: packages/ssh/src/tunnel.ts (REMOTE_STOP_SCRIPT: did not stop within 2 seconds)
  @backlog @desktop
  Scenario: A launched server that does not stop in time is reported and still owned
    Given an SSH environment whose server the desktop app launched
    And that server does not stop when asked
    When the user removes it
    Then the user is told the server did not stop within two seconds
    And the app still counts the server as its own for the next attempt

  # Legacy: packages/ssh/src/tunnel.ts (ensureTunnelEntry: existing.stale, withTargetLock)
  @backlog @desktop
  Scenario: A connection that went stale is rebuilt when the environment is used again
    Given a connected SSH environment whose forwarded connection no longer answers
    When the app connects to the environment again
    Then the old forwarded connection is closed
    And a new one is made to the same server

  # Legacy: packages/ssh/src/tunnel.ts (withTargetLock: reconnect cannot reuse a server while stop is pending)
  @backlog @desktop
  Scenario: Reconnecting waits for a stop that is still in progress
    Given the user is removing an SSH environment whose server the app launched
    When the same host is connected again before the server has stopped
    Then the connection waits for the stop to finish
    And it does not reuse the server that is stopping

  # Legacy: packages/ssh/src/tunnel.ts (targetConnectionKey, remoteStateKey)
  @backlog @desktop
  Scenario Outline: The same host as another user or on another port is a separate environment
    Given an SSH environment to "devbox" as "ada" on port 22
    When the user adds another SSH environment to "devbox" with <difference>
    Then it has its own server, tunnel and record on the host
    And removing one leaves the other running

    Examples:
      | difference         |
      | the user "grace"   |
      | the port 2222      |

  # Legacy: packages/ssh/src/command.ts (redactSshErrorOutput, MAX_SSH_ERROR_OUTPUT_LENGTH)
  @backlog @desktop
  Scenario: An SSH failure never shows the credentials in the host's output
    Given the host's output on a failed launch includes a pairing token or a bearer token
    When the connection fails
    Then the failure message shows the output with those secrets hidden

  # Legacy: packages/ssh/src/command.ts (MAX_SSH_ERROR_OUTPUT_LENGTH = 4000)
  @backlog @desktop
  Scenario: A very long SSH failure is cut short and says so
    Given the host's output on a failed launch is far longer than a dialog can show
    When the connection fails
    Then the failure message shows the beginning of that output
    And it says the rest was left out

  # Legacy: packages/ssh/src/command.ts (ConnectTimeout=10), tunnel.ts (SSH_READY_TIMEOUT_MS)
  @backlog @desktop
  Scenario: A host that does not answer is given up on instead of waited on
    Given the SSH host does not answer at all
    When the user connects to the SSH environment
    Then the connection fails after a short wait rather than hanging
    And the user can try again

  # Legacy: packages/ssh/src/tunnel.ts (startSshTunnel: tunnel process exit surfaces ssh message)
  @backlog @desktop
  Scenario: A tunnel that ssh closes at once shows ssh's own message
    Given the host accepts the launch but ssh refuses to forward the port
    When the user connects to the SSH environment
    Then the connection fails with the message ssh printed

  # Legacy: packages/ssh/src/command.ts (resolveSshTarget: ssh -G, falls back to the typed name)
  @backlog @desktop
  Scenario: A host name is resolved with the user's SSH config before connecting
    Given the user's SSH config maps "devbox" to a host name, a user and a port
    When the user adds an SSH environment to "devbox"
    Then the connection uses that host name, user and port
    And a user or port typed in the dialog wins over the config's

  # Legacy: packages/ssh/src/command.ts (resolveSshTarget fallback)
  @backlog @desktop
  Scenario: A host name the SSH config cannot resolve is connected to as typed
    Given the user's SSH config does not name "build.example"
    When the user adds an SSH environment to "build.example"
    Then the connection goes to "build.example" as typed

  # The hosted app at app.hal-c2.example connects to an MC over HTTPS. HAL-C2 has no hosted web
  # client; QML clients connect over plain HTTP on a LAN or tailnet.
  @dropped @mc
  Scenario: A hosted HTTPS client connects only to HTTPS environments
    Given the environment offers only a plain HTTP address
    When the hosted app tries to connect
    Then the browser blocks the connection
