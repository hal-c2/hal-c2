# Sources:
#   https://github.com/pingdotgg/t3code/pull/20272
#   https://github.com/pingdotgg/t3code/pull/15630
#   https://github.com/pingdotgg/t3code/pull/20059
#   https://github.com/pingdotgg/t3code/pull/15753
#   https://github.com/pingdotgg/t3code/pull/18832
#   https://github.com/pingdotgg/t3code/pull/20445
#   https://github.com/pingdotgg/t3code/pull/17158
#   https://github.com/pingdotgg/t3code/pull/19372
#   https://github.com/pingdotgg/t3code/pull/19432
#   https://github.com/pingdotgg/t3code/pull/15468
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
#   connections/hal-c2-connect.feature holds the dropped HAL-C2 Connect relay;
#   settings/connections.feature holds the desktop network access, Tailscale HTTPS and add-over-SSH controls.

Feature: How clients reach an environment
  An MC listens on loopback unless told otherwise. Clients reach it directly on a LAN or
  tailnet, over Tailscale HTTPS, through a desktop-managed SSH forward, or through another MC of
  theirs in the same cluster.

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

  @backlog @desktop @priority-low
  Scenario: Turning off network access keeps Tailscale HTTPS working
    Given network access is on
    And the environment is also reachable through Tailscale HTTPS
    When the user turns network access off
    Then devices on the local network disconnect
    And Tailscale HTTPS keeps working

  @backlog @desktop @priority-low
  Scenario: Tailscale HTTPS without Tailscale explains itself
    Given Tailscale is not running on this machine
    When the user turns on Tailscale HTTPS
    Then the client says to start Tailscale to set up HTTPS through MagicDNS

  # Replaces the hosted HAL-C2 Connect relay: the rendezvous is a member the user runs.
  @backlog @mc
  Scenario: A machine behind NAT is reached through the user's MC with a public address
    Given the user runs an MC on a machine with a public address
    And another of the user's MCs is behind NAT with no address the user's devices can reach
    When the MC behind NAT joins the public MC's cluster
    Then the user's devices and other MCs reach the MC behind NAT through the public MC
    And no HAL-C2-hosted service carries the traffic

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

  # An installed MC has no Mix: its operator runs the single file (hal-c2-service pair).
  @mc
  Scenario: A taken Tailscale port names the command an installed MC is paired with
    Given the default tailnet HTTPS port is in use
    And the MC was started from an installed release
    When an operator asks for a Tailscale pairing link on the taken port
    Then the refusal tells them to run "hal-c2-service pair"

  @backlog @desktop @priority-high
  Scenario: The first SSH launch installs the server on the host
    Given a host that has never run HAL-C2
    When the user adds it as an SSH environment
    Then the server is downloaded to the host's runtime folder before it starts

  # Upstream #15630: discovery listed both a configured alias and its known-hosts address.
  @backlog @desktop
  Scenario: A configured SSH host is suggested by its alias only
    Given the SSH config names "build" with the address "10.0.0.5" and a user and port of its own
    And "10.0.0.5" is in the known hosts
    When the user looks for an SSH host to add
    Then "build" is suggested and "10.0.0.5" is not
    And searching for "10.0.0.5" finds "build"

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

  @backlog @desktop @priority-high
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

  @backlog @desktop @priority-low
  Scenario: An SSH launch keeps the port the host used last when it is free
    Given the host's server last ran on a port that is free
    When the user connects to the SSH environment
    Then the server starts on that port

  @backlog @desktop @priority-low
  Scenario: An SSH launch takes the next free port when the usual one is taken
    Given the port the host's server used last is taken by another program
    When the user connects to the SSH environment
    Then the server starts on the next free port after it

  # Upstream #19372: an SSH launch no longer picks a port another server answers on
  @backlog @desktop
  Scenario: An SSH launch skips a port another server already answers on
    Given another server on the host listens on every address on the port the launch would pick
    And the host lets a loopback test bind succeed on that port anyway
    When the user connects to the SSH environment
    Then the server starts on a port nothing answers on
    And the host shows no firewall prompt for the check

  @backlog @desktop @priority-low
  Scenario: An SSH launch fails when no port is free in the range it tries
    Given every port in the range the launch tries is taken
    When the user connects to the SSH environment
    Then the connection fails saying no port was available on the host

  @backlog @desktop
  Scenario: An SSH launch fails when the server never answers
    Given the server on the host starts but does not answer its health check in time
    When the user connects to the SSH environment
    Then the connection fails saying the server did not become ready

  @backlog @desktop @priority-high
  Scenario: An SSH host that asks for a password
    Given an SSH host that needs a password
    When the desktop app connects
    Then the user is asked for the password
    And the password is not kept after the connection

  @backlog @desktop @priority-low
  Scenario: The password prompt names the host and the user it is for
    Given an SSH host that needs a password for "olafur@build-box"
    When the desktop app connects
    Then the prompt names "olafur@build-box"
    And it says the password is used for this connection attempt only and is not saved

  # Upstream #20272: the SSH prompt asks for a password or verification code.
  @backlog @desktop
  Scenario: An SSH host that asks for a verification code gets one
    Given an SSH host that asks for a verification code after the password
    When the user connects to it
    Then the prompt asks for a password or verification code
    And the code the user enters is sent to the host

  @backlog @desktop @priority-low
  Scenario: A password prompt that was not answered in time expires
    Given the password prompt for an SSH host is showing a countdown
    When the time runs out
    Then the prompt says it expired and cannot be answered
    And the user is told to try connecting again

  @backlog @desktop @priority-low
  Scenario: Cancelling the password prompt stops the connection without retrying
    Given an SSH host that needs a password
    When the user cancels the password prompt
    Then the connection stops
    And it is not retried until the user connects again

  @backlog @desktop @priority-low
  Scenario: Several hosts asking for a password are asked one at a time
    Given two SSH hosts that each need a password
    When the desktop app connects to both
    Then the user is asked for the first host's password
    And the second host's prompt follows once the first is answered or cancelled

  # Legacy: apps/desktop/src/ssh/DesktopSshPasswordPrompts.ts
  @backlog @desktop @priority-low
  Scenario: The password prompt comes to the front of a minimized window
    Given an SSH host that needs a password
    And the app's window is minimized
    When the desktop app connects
    Then the window is restored and brought forward
    And the user is asked for the password

  @backlog @desktop @priority-low
  Scenario: Closing the window cancels a waiting password prompt
    Given the user is being asked for an SSH host's password
    When the user closes the app's window
    Then the connection fails saying the authentication was cancelled because the window closed

  @backlog @desktop @priority-low
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

  @backlog @desktop @priority-high
  Scenario: A saved SSH environment reconnects without pairing again
    Given a saved SSH environment
    When the desktop app restarts
    Then it reconnects over SSH without a new pairing link

  # Upstream #20445: one host session per desktop and SSH route, instead of a new one per connect.
  @backlog @desktop @priority-high
  Scenario: Reconnecting to an SSH environment reuses its session on the host
    Given a saved SSH environment the desktop app has connected to once
    When the desktop app reconnects or restarts
    Then it signs in with the session it saved for that route
    And the host has no new session for this desktop

  # Upstream #20445: a session that can no longer be used is replaced by pairing once.
  @backlog @desktop
  Scenario Outline: An SSH environment whose saved session cannot be used pairs once more
    Given a saved SSH environment whose session on the host <state>
    When the desktop app reconnects
    Then it pairs once and saves the new session
    And the next reconnect reuses that session

    Examples:
      | state                      |
      | was revoked                |
      | has expired                |
      | lacks a scope clients need |

  # Upstream #20445: a failed session check is retried and never pairs.
  @backlog @desktop
  Scenario: A failed check of a saved SSH session is retried without pairing
    Given a saved SSH environment whose host cannot answer the session check
    When the desktop app reconnects
    Then the connection attempt fails and is tried again
    And the desktop app does not pair

  # Upstream #20445: a saved SSH route that now reaches another environment is refused.
  @backlog @desktop @priority-high
  Scenario: A saved SSH route that reaches a different environment is refused
    Given a saved SSH environment whose host now runs a different environment
    When the desktop app reconnects
    Then the connection fails before pairing or sending the saved session

  # Legacy: apps/desktop/src/ipc/methods/sshEnvironment.ts (DesktopSshEnvironmentRequestError)
  @backlog @desktop @priority-low
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

  # Upstream #19432: reconnecting keeps the remote server and its agents running
  @backlog @desktop @priority-high
  Scenario: Reconnecting reuses the server the app launched
    Given an SSH environment whose server the desktop app launched
    And that server recorded itself in the host's runtime record
    When the laptop wakes from sleep and the app reconnects
    Then the app connects to the same server
    And the agents running on the host keep running

  # Upstream #19432: reconnecting keeps the remote server and its agents running
  @backlog @desktop
  Scenario: Reconnecting waits for a busy server instead of replacing it
    Given an SSH environment whose launched server is slow to answer but still running
    When the app reconnects
    Then it waits as long as it would for a cold start
    And if the server still does not answer the reconnect fails and can be retried
    And the server keeps running

  # Upstream #19432: reconnecting keeps the remote server and its agents running
  @backlog @desktop
  Scenario: Replacing a dead forward closes only the local tunnel
    Given an SSH environment whose local forward died while the network was down
    When the app reconnects
    Then a new forward is opened to the same server
    And the server on the host is not stopped

  # Upstream #18832: an SSH tunnel keeps working while ssh keeps printing diagnostics.
  @backlog @mc @priority-low
  Scenario: A talkative SSH connection keeps forwarding
    Given the user's SSH configuration makes ssh print verbose diagnostics
    When an SSH environment's tunnel is ready and ssh keeps printing
    Then the environment stays reachable through the tunnel

  # Upstream #19432: reconnecting keeps the remote server and its agents running
  @backlog @desktop @priority-high
  Scenario: A crashed launched server is replaced on reconnect
    Given an SSH environment whose launched server crashed and was not reaped
    When the app reconnects
    Then a new server is started on the host

  @backlog @desktop @priority-low
  Scenario: A failed SSH reconnect after an update can be retried
    Given an SSH environment fails to reconnect after an app update
    When the user retries the launch
    Then the environment reconnects

  # Legacy: packages/ssh/src/tunnel.ts (handleSshAuthFailure: promptCount >= 2)
  @backlog @desktop @priority-low
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
  @backlog @desktop @priority-low
  Scenario: A downloaded server that cannot run on the host is not kept for later launches
    Given a host that has never run HAL-C2
    And the downloaded server cannot run on that host
    When the user adds it as an SSH environment
    Then the connection fails saying the server does not run on the host
    And the next connection downloads and checks it again

  # Legacy: packages/ssh/src/tunnel.ts (hal_c2_fetch: curl or wget)
  @backlog @desktop @priority-low
  Scenario: A host that can download neither with curl nor with wget says what it needs
    Given a host that has never run HAL-C2 and has neither curl nor wget
    When the user adds it as an SSH environment
    Then the connection fails saying the host needs curl or wget to download the server

  # Upstream #20059: two installs racing on a mkdir that wrongly succeeds no longer unpack the server twice.
  # Legacy: packages/ssh/src/tunnel.ts (REMOTE_RUNNER_SCRIPT install lock)
  @backlog @desktop @priority-low
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
  @backlog @desktop @priority-low
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
  @backlog @desktop @priority-low
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
  @backlog @desktop @priority-low
  Scenario: Reconnecting waits for a stop that is still in progress
    Given the user is removing an SSH environment whose server the app launched
    When the same host is connected again before the server has stopped
    Then the connection waits for the stop to finish
    And it does not reuse the server that is stopping

  # Legacy: packages/ssh/src/tunnel.ts (targetConnectionKey, remoteStateKey)
  @backlog @desktop @priority-low
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
  @backlog @desktop @priority-low
  Scenario: An SSH failure never shows the credentials in the host's output
    Given the host's output on a failed launch includes a pairing token or a bearer token
    When the connection fails
    Then the failure message shows the output with those secrets hidden

  # Legacy: packages/ssh/src/command.ts (MAX_SSH_ERROR_OUTPUT_LENGTH = 4000)
  @backlog @desktop @priority-low
  Scenario: A very long SSH failure is cut short and says so
    Given the host's output on a failed launch is far longer than a dialog can show
    When the connection fails
    Then the failure message shows the beginning of that output
    And it says the rest was left out

  # Legacy: packages/ssh/src/command.ts (ConnectTimeout=10), tunnel.ts (SSH_READY_TIMEOUT_MS)
  @backlog @desktop @priority-low
  Scenario: A host that does not answer is given up on instead of waited on
    Given the SSH host does not answer at all
    When the user connects to the SSH environment
    Then the connection fails after a short wait rather than hanging
    And the user can try again

  # Legacy: packages/ssh/src/tunnel.ts (startSshTunnel: tunnel process exit surfaces ssh message)
  @backlog @desktop @priority-low
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
  @backlog @desktop @priority-low
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

  # Upstream #15468: clients learn an environment's LAN and tailnet addresses
  @backlog @mc @shared
  Scenario: A client learns an environment's other addresses once connected
    Given an MC bound to a LAN address and a tailnet address
    And a client paired over only one of them
    When the client's session is ready
    Then the MC reports the addresses it is bound to
    And the client saves the new ones as routes marked as found automatically, ranked by kind
    And a loopback-only MC reports none

  # Upstream #15468: clients learn an environment's LAN and tailnet addresses
  @backlog @shared
  Scenario: A learned route follows the host's address
    Given a client holds a route it learned from the MC
    When the MC stops reporting that address and reports a new one
    Then the old learned route is dropped and the new one saved
    And a route the user paired is never rewritten
    And the live session is not replaced by the change, only by the better-route check

  # Upstream #20445: a credential paired over HTTPS, loopback or the tailnet is not copied to a
  # learned plain-HTTP address on the local network or the internet; tailnet addresses are still learned.
  @backlog @shared @priority-high
  Scenario Outline: A credential paired over a secure route is not lent to a plain HTTP address off the tailnet
    Given a client paired with the environment over <paired>
    When the client learns a plain HTTP address on <learned>
    Then the learned address <outcome>

    Examples:
      | paired                          | learned           | outcome                           |
      | HTTPS                           | the local network | is not saved with that credential |
      | loopback                        | the internet      | is not saved with that credential |
      | the tailnet                     | the local network | is not saved with that credential |
      | plain HTTP on the local network | the local network | is saved with that credential     |
      | HTTPS                           | the tailnet       | is saved with that credential     |

  # Upstream #15753: a Proton VPN address in 100.64/10 is no longer advertised as Tailscale in pairing links
  # Upstream #17158: Cloudflare and other VPN addresses no longer show as Tailscale
  @backlog @mc @priority-low
  Scenario Outline: An address in the shared 100.64/10 range is a tailnet address only on Tailscale's own interface
    Given the MC's machine has the address "100.96.0.1" on <interface>
    When the MC reports the addresses it is bound to
    Then "100.96.0.1" is reported as <kind>

    Examples:
      | interface                                | kind                    |
      | Tailscale's network interface            | a tailnet address       |
      | a Cloudflare WARP or other VPN interface | a local network address |

  # Upstream #17158: Cloudflare and other VPN addresses no longer show as Tailscale
  @backlog @shared @priority-low
  Scenario Outline: A route is labelled Tailscale only with proof
    Given a client has a route to "<host>"
    And <proof>
    When the user looks at the environment's routes
    Then the route is labelled "<label>"

    Examples:
      | host                | proof                                                   | label     |
      | 100.101.102.103     | the MC reported that address as a tailnet address       | Tailscale |
      | devbox.tail1.ts.net | the host is a Tailscale name                            | Tailscale |
      | 100.96.0.1          | the MC reported that address as a local network address | VPN       |
