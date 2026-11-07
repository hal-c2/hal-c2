# Sources:
#   https://github.com/pingdotgg/t3code/pull/27817
#   https://github.com/pingdotgg/t3code/pull/22089
#   https://github.com/pingdotgg/t3code/pull/23343
#   https://github.com/pingdotgg/t3code/pull/23789
#   https://github.com/pingdotgg/t3code/pull/19902
#   https://github.com/pingdotgg/t3code/pull/10958
#   docs/user/remote-access.md (Pair over a LAN or private network, Manage or revoke access)
#   docs/operations/development.md (vp run dev --share pairing URL, Reusable dev credential)
#   docs/internals/environment-auth.md (Authority survives transport changes)
#   apps/server-ex/lib/mix/tasks/hal_c2.pair.ex, apps/server-ex/lib/hal_c2/pair.ex,
#     apps/server-ex/rel/overlays/bin/hal-c2-service (pair)
#   apps/server-ex/lib/hal_c2/auth.ex, apps/server-ex/lib/hal_c2/web/router.ex (/oauth/token, pairing links,
#     /pair: the page a phone's camera app opens)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.createPairingLink), apps/server-ex/lib/hal_c2/web.ex (address/1:
#     where a link's MC is reached), apps/server-ex/lib/hal_c2/tailscale_serve.ex
#   apps/web/src/components/settings/ConnectionsSettings.tsx (Add environment, Create pairing link,
#     pairing link scopes, QR code, hosted app link, pairing code)
#   apps/web/src/components/settings/pairingUrls.ts
#   apps/server/src/startupAccess.ts (printed link, token in the fragment, QR code, wildcard host)
#   apps/desktop-qt/src/native/ConnectionsController.cpp (a created link's secret lives only while the page is open)
#   packages/shared/src/remote.ts, packages/client-runtime/src/connection/onboarding.ts
#     (a host without a scheme: HTTPS, then plain HTTP)
#   apps/web/src/components/auth/PairingRouteSurface.tsx
#   apps/web/src/hostedPairing.ts (hosted pairing request, hosted channel selection)
#   apps/mobile/src/features/connection/pairing.ts (host and code, QR payloads)
#   apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx
#   apps/desktop-qt/host/pairingUrl.ts (pairing URL announced by a server)
#   apps/tui/src/features.backlog.test.ts (environment-access-management)
#   docs/user/remote-access.md (HAL-C2 auth)
#   packages/contracts/src/auth.ts (pairing link, scopes)
#   Shared domain: tui/launch.feature holds pairing the terminal client from its command line;
#   mobile/pairing-and-environments.feature holds pairing from a phone;
#   settings/connections.feature holds creating, copying and revoking links on the desktop page.
#   https://github.com/pingdotgg/t3code/pull/25591
#   https://github.com/pingdotgg/t3code/pull/26178
#   https://github.com/pingdotgg/t3code/pull/26318

Feature: Pairing a client with an environment
  Pairing turns a one-time link into a lasting session for one device. Links are minted on
  the host, carry a set of scopes, work once and expire after five minutes.

  Background:
    Given a running MC

  @mc
  Scenario: An operator prints a pairing link on the host
    When an operator asks the MC for a pairing link with its LAN address
    Then it prints the address with a one-time token
    And the token grants standard scopes for five minutes
  # Upstream #22089: a pairing code typed in lowercase was refused, and the phone's code field
  # does not capitalise.
  @backlog @mc
  Scenario: A pairing code is accepted in any letter case
    Given an operator printed the pairing code "K7QX2MRP9TWD"
    When a device pairs with the code typed as "k7qx2mrp9twd"
    Then the device pairs
    And the code cannot be used again in either case

  # Upstream #22089: only the pairing code's own form is folded.
  @backlog @mc @priority-low
  Scenario: A credential that is not a pairing code must match its case
    Given the desktop app was started with a lowercase credential of its own
    When a device pairs with that credential in uppercase
    Then the pairing is refused


  # Upstream #23789: pairing against an MC on another protocol printed a token it could not use.
  @backlog @mc
  Scenario: A pairing command refuses an MC that speaks another protocol
    Given the running MC speaks another protocol than the pairing command
    When an operator asks for a pairing link
    Then the command fails naming both protocols and the command that pairs with that MC
    And no token, database or tailnet setting is written

  @mc
  Scenario: A pairing link names the address the operator gives it
    When an operator asks for a pairing link for "https://box.tailnet.ts.net"
    Then the printed link starts with that address

  # The single file's `pair` runs the same code as the Mix task, in the release with no Mix.
  @mc
  Scenario: An installed MC prints a pairing link from its single file
    When an operator runs "pair https://box.tailnet.ts.net" on the installed MC's command line
    Then it prints the address with a one-time token

  # Upstream #27817: a startup clean-up logged a line to standard output before a token
  # printed for a script, so `TOKEN=$(...)` captured both.
  @backlog @mc @priority-low
  Scenario: A pairing link captured by a script is all the command prints to standard output
    Given the MC's home holds an abandoned upload that is cleaned up when a command starts
    When an operator captures the standard output of asking for a pairing link
    Then the captured text is only the pairing link

  @mc
  Scenario: A pairing command given an option it does not have says so
    Given an administrator's client
    When an operator asks for a pairing link with the option "--tailnet"
    Then the command fails naming "--tailnet"
    And no pairing link is listed

  # Upstream #23343: `t3 auth pairing create --base-url` without http(s):// is refused before a token is issued.
  @backlog @mc
  Scenario Outline: A pairing link for an address that is not http or https is refused before a token is issued
    Given an administrator's client
    When an operator asks for a pairing link for "<address>"
    Then the command fails saying the address must start with http:// or https://
    And no pairing link is listed

    Examples:
      | address            |
      | 192.168.1.5:3773   |
      | localhost:3773     |
      | ftp://box.lan:3773 |

  @mc
  Scenario: A pairing command given two addresses says it takes one
    Given an administrator's client
    When an operator asks for a pairing link with the arguments "https://a.example https://b.example"
    Then the command fails naming "at most one"
    And no pairing link is listed

  @mc
  Scenario Outline: A pairing command given an address a link cannot be built on says so
    Given an administrator's client
    When an operator asks for a pairing link for the one address "<address>"
    Then the command fails naming "BASE_URL must be an http or https address"
    And no pairing link is listed

    Examples:
      | address                         |
      | box.tailnet.ts.net              |
      | localhost:3780                  |
      | ftp://box.example               |
      | https://box.example/?a=1        |
      | https://box.example/#top        |
      | http://user:pass@127.0.0.1:3780 |
      | http://host:abc                 |
      | http://127.0.0.1:99999          |
      | http://exa mple.com             |
      | https://box.example/some path   |

  @mc
  Scenario: A pairing command given an address with credentials does not print them back
    Given an administrator's client
    When an operator asks for a pairing link for the one address "http://user:pass@127.0.0.1:3780"
    Then the command fails naming "BASE_URL must be an http or https address"
    And the command does not print "user:pass"
    And no pairing link is listed

  @mc
  Scenario: A pairing command given a pasted pairing link does not print its token back
    Given an administrator's client
    When an operator asks for a pairing link for the one address "https://box.example/?token=sekrit"
    Then the command fails naming "BASE_URL must be an http or https address"
    And the command does not print "sekrit"
    And no pairing link is listed

  @mc
  Scenario: A pairing command given a bad value says which one
    Given an administrator's client
    When an operator asks for a pairing link with the option "--tailscale-serve-port=foo"
    Then the command fails naming "--tailscale-serve-port=foo"
    And no pairing link is listed

  @mc
  Scenario: A Tailscale pairing command given an address says it takes none
    Given an administrator's client
    When an operator asks for a pairing link with the arguments "--tailscale https://a.example"
    Then the command fails naming "takes no BASE_URL"
    And no pairing link is listed

  @mc
  Scenario: A Tailscale Serve port without Tailscale says so
    Given an administrator's client
    When an operator asks for a pairing link with the option "--tailscale-serve-port=8443"
    Then the command fails naming "only applies with `--tailscale`"
    And no pairing link is listed

  @mc
  Scenario: A Tailscale Serve port outside the port range says so
    Given an administrator's client
    When an operator asks for a pairing link with the arguments "--tailscale --tailscale-serve-port 70000"
    Then the command fails naming "1 to 65535"
    And no pairing link is listed

  # Upstream #10958: a tailnet without HTTPS certificates made Serve pairing time out unexplained.
  @backlog @mc
  Scenario: A tailnet with HTTPS turned off says so instead of timing out
    Given the tailnet has HTTPS certificates turned off
    When the user pairs through Tailscale
    Then the user is told HTTPS is off for the tailnet and to turn it on in the Tailscale admin DNS settings
    And no Tailscale Serve is started

  @backlog @mc @priority-high
  Scenario: A pairing link keeps its token out of the address a server sees
    When an operator asks the MC for a pairing link
    Then the printed link carries its token after a "#", not in the query

  @backlog @mc
  Scenario: A pairing link printed on the host can be scanned
    When an operator asks the MC for a pairing link
    Then the output holds the link, its token and a QR code of the link
    And the QR code is drawn in the terminal with block characters

  @backlog @mc
  Scenario: An MC listening on every interface prints an address a device can reach
    Given the MC listens on every network interface
    When an operator asks the MC for a pairing link without naming an address
    Then the link names one of the machine's non-loopback addresses
    And the port is the one the MC actually listens on

  @mc
  Scenario: An administrator creates a labelled pairing link
    Given an administrator's client
    When it creates a pairing link labelled "Living room iPad" with standard scopes
    Then the MC returns the link's credential once
    And the link is listed under that label until it is used

  # hal-c2.createPairingLink: the MC that makes a link says where another device reaches
  # it, which a client cannot know of a machine it is not connected to. A link for another
  # member of a cluster is in connections/cluster.feature.
  @mc
  Scenario Outline: A pairing link says where a device reaches its MC
    Given the MC listens on <listening>
    And an administrator's client
    When it asks the MC for a pairing link <asking>
    Then the link comes with <address>
    And that address is <reach>

    Examples:
      | listening               | asking                           | address                                  | reach                             |
      | its LAN address         | at the address it listens on     | the MC's LAN address                     | one another device can reach      |
      | every network interface | at the address it listens on     | a network address of its machine         | one another device can reach      |
      | its own machine only    | at the address it listens on     | the MC's loopback address                | reachable only on its own machine |
      | its own machine only    | at "https://box.tailnet.ts.net/" | the address "https://box.tailnet.ts.net" | one another device can reach      |
      | its own machine only    | at "http://127.0.0.2:4000"       | the address "http://127.0.0.2:4000"      | reachable only on its own machine |
      | its own machine only    | at "http://LocalHost:4000"       | the address "http://LocalHost:4000"      | reachable only on its own machine |
      | its own machine only    | at "http://[::1]:4000"           | the address "http://[::1]:4000"          | reachable only on its own machine |

  @mc
  Scenario: A pairing link over Tailscale publishes its MC on the tailnet
    Given Tailscale names the MC's machine "box.tail5e3a.ts.net"
    And an administrator's client
    When it asks the MC for a pairing link over Tailscale
    Then Tailscale serves the MC over HTTPS at "box.tail5e3a.ts.net"
    And the link comes with the address "https://box.tail5e3a.ts.net"
    And that address is one another device can reach

  # Upstream #19902: Tailscale Serve targets the IPv6 loopback when the server listens only on ::1.
  # Its Connect half is dropped with HAL-C2 Connect.
  @backlog @mc
  Scenario: A Tailscale pairing reaches an MC that listens only on ::1
    Given the MC listens only on "::1"
    When the user makes a pairing link over Tailscale
    Then the tailnet address reaches the MC

  @mc
  Scenario: No pairing link is made when Tailscale cannot publish the MC
    Given Tailscale is not running on the MC's machine
    And an administrator's client
    When it asks the MC for a pairing link over Tailscale
    Then the client is told Tailscale could not be reached
    And no pairing link is listed

  # What a phone's own camera app opens when it reads the QR code of a pairing link
  # (`<address>/pair#token=…`). The token is in the fragment, which a browser keeps to
  # itself, so the page makes the app's link (`hal-c2://pair?pairingUrl=…`) in the browser.
  @mc
  Scenario: A pairing link opened in a phone's browser offers to open the app
    When a phone's browser opens a pairing link
    Then the page names the MC and offers to open the HAL-C2 app
    And it hands the app its own address as "hal-c2://pair?pairingUrl="
    And it says what to do when the app is not installed
    And nothing but the page's own script and style may load

  @mc
  Scenario: A used pairing link leaves the list
    Given a listed pairing link
    When a device pairs with it
    Then the link is no longer listed
    And the device is listed as a client

  @mc
  Scenario: A revoked pairing link no longer pairs
    Given a listed pairing link
    When an administrator revokes it
    Then pairing with it fails

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui @priority-high
  Scenario: The user pairs by pasting a pairing link
    Given a pairing link from another machine
    When the user adds an environment with that link
    Then the client pairs and lists the environment
    And connects to it

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui @priority-high
  Scenario: The user pairs by entering a host and a pairing code
    When the user adds an environment with host "192.168.1.20:3780" and a pairing code
    Then the client pairs with that environment

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: A host typed without a scheme reaches an MC that serves plain HTTP
    Given an MC on the LAN that serves plain HTTP
    When the user adds an environment with host "ai-beast:3780" and a pairing code
    Then the client tries HTTPS first and pairs over HTTP when that cannot connect

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: An expired or used pairing link explains itself
    Given a pairing link that already paired another device
    When the user adds an environment with it
    Then the client says the link is invalid or expired
    And asks for a fresh link

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: An unreachable host fails pairing with a reason
    When the user pairs with a host that does not answer
    Then the client says the connection failed
    And offers the trace id for a bug report

  @desktop
  Scenario: A new pairing link can only be copied while its page is open
    Given the user created a pairing link
    When the user leaves the Connections page and comes back
    Then the link is listed without its secret
    And the user must create another link to share

  @shared @backlog-mobile @backlog-tui
  Scenario: Pairing again with a fresh link replaces a lost session
    Given a device whose session was revoked
    When the user pairs it again with a fresh link
    Then it reconnects with a new session
    And keeps its local view of the environment

  # Upstream #25591: a fresh link pasted at another address of a known environment was exchanged,
  # but the client kept connecting with its older, narrower session.
  # Upstream #26178: only a route the user adds from that environment's settings may bring a new
  # address, so the link here is used from there.
  @backlog @shared
  Scenario: Pairing a known environment at another address connects with the new session
    Given a device paired with an environment at "127.0.0.1:3773"
    When the user adds a route to it from its settings with a fresh link at "localhost:3773"
    Then it connects with the new link's session and its access
    And the earlier address is kept as a fallback with its own session

  # Upstream #26178: an environment names its own id, so a link to a server claiming a saved
  # environment's id could add itself as that environment's fallback and serve it fake threads.
  @backlog @shared @priority-high
  Scenario Outline: A pairing link not started from an environment cannot add an address to it
    Given a device paired with the environment "work" at "work.lan:3773"
    When the user pairs with a link to <address> whose server says it is "work"
    Then <outcome>

    Examples:
      | address            | outcome                                                              |
      | "evil.example:3773" | the pairing is refused and "work" keeps only "work.lan:3773"         |
      | "work.lan:3773"     | "work" is paired again at "work.lan:3773" with the new session       |

  # Upstream #26318: on the phone a link could open the pairing form already aimed at a saved
  # environment, so a code entered there added its server as one of that environment's routes.
  @backlog @mobile @priority-high
  Scenario: A link to the phone's pairing form cannot aim it at a saved environment
    Given the phone has the saved environment "work"
    When the user opens a link to the pairing form that names "work" as the environment to add a route to
    Then the form adds a new environment, not a route to "work"
    And adding a route from "work"'s own settings still aims the form at "work"

  # Access to the machine the terminal is connected to is managed from its connection
  # settings (the `authAccess` stream, `hal-c2.revokeClient`, `hal-c2.revokeOtherClients`).
  @tui
  Scenario: The terminal client lists live access changes
    Given the user administers the environment
    When the user opens access management in the terminal client
    Then it lists pairing links and paired clients
    And updates the list when another client pairs

  @tui
  Scenario: The terminal client revokes one client
    Given another paired client
    When the user revokes it from the terminal client
    Then that client can no longer connect

  @tui
  Scenario: The terminal client revokes every other client
    Given three other paired clients
    When the user revokes every other client
    Then only the terminal client's own session remains

  # The hosted app.hal-c2.example pairing link. HAL-C2 has no hosted web app; QML clients pair
  # with the MC's own link.
  @dropped @desktop
  Scenario: The user copies a hosted app pairing link
    Given the environment is reachable over HTTPS
    When the user copies the hosted app link
    Then a browser can pair through app.hal-c2.example without installing anything

  # The hosted app's pairing page is a browser route. QML clients pair from the app itself.
  @dropped @desktop
  Scenario: A hosted app pairing link without its host or token says so
    Given the hosted app is opened from a pairing link that has no host or no token
    Then the page says the link is missing its backend host or token
    And it offers no retry

  # The hosted app's pairing page is a browser route. QML clients pair from the app itself.
  @dropped @desktop
  Scenario: A hosted app pairing token is submitted only once
    Given the hosted app already submitted the link's one-time token
    When the user asks to pair again from the same page
    Then the page says the token was already submitted and to request a new pairing link

  # The hosted app's pairing page is a browser route. QML clients pair from the app itself.
  @dropped @desktop
  Scenario: A hosted app pairing that fails hints at the browser's limits
    Given the backend is not reachable from the browser, does not allow hosted clients, or is not served over HTTPS
    When the hosted app tries to pair
    Then the page says pairing failed and shows the host
    And it says to verify reachability, CORS for hosted clients and HTTPS
    And it says to request a new pairing link if the backend accepted the token

  # The hosted app's update track switches which deployed build a browser loads; there is no hosted app.
  @dropped @desktop
  Scenario Outline: The hosted app switches between the latest and nightly builds
    Given the user opened the hosted app on the <from> build
    When the user switches the update track to <to>
    Then the browser loads the hosted app's <to> build

    Examples:
      | from    | to      |
      | latest  | nightly |
      | nightly | latest  |
