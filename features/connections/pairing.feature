# Sources:
#   docs/user/remote-access.md (Pair over a LAN or private network, Manage or revoke access)
#   docs/operations/development.md (vp run dev --share pairing URL, Reusable dev credential)
#   docs/internals/environment-auth.md (Authority survives transport changes)
#   apps/server-ex/lib/mix/tasks/hal_c2.pair.ex
#   apps/server-ex/lib/hal_c2/auth.ex, apps/server-ex/lib/hal_c2/web/router.ex (/oauth/token, pairing links)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (Add environment, Create pairing link,
#     pairing link scopes, QR code, hosted app link, pairing code)
#   apps/web/src/components/settings/pairingUrls.ts
#   apps/desktop-qt/src/native/ConnectionsController.cpp (a created link's secret lives only while the page is open)
#   packages/shared/src/remote.ts, packages/client-runtime/src/connection/onboarding.ts
#     (a host without a scheme: HTTPS, then plain HTTP)
#   apps/web/src/components/auth/PairingRouteSurface.tsx
#   apps/mobile/src/features/connection/pairing.ts (host and code, QR payloads)
#   apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx
#   apps/desktop-qt/host/pairingUrl.ts (pairing URL announced by a server)
#   apps/tui/src/features.backlog.test.ts (environment-access-management)
#   docs/user/remote-access.md (HAL-C2 auth)
#   packages/contracts/src/auth.ts (pairing link, scopes)
#   Shared domain: tui/launch.feature holds pairing the terminal client from its command line;
#   mobile/pairing-and-environments.feature holds pairing from a phone;
#   settings/connections.feature holds creating, copying and revoking links on the desktop page.

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

  @mc
  Scenario: A pairing link names the address the operator gives it
    When an operator asks for a pairing link for "https://box.tailnet.ts.net"
    Then the printed link starts with that address

  @mc
  Scenario: An administrator creates a labelled pairing link
    Given an administrator's client
    When it creates a pairing link labelled "Living room iPad" with standard scopes
    Then the MC returns the link's credential once
    And the link is listed under that label until it is used

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
  @backlog @tui
  Scenario: The user pairs by pasting a pairing link
    Given a pairing link from another machine
    When the user adds an environment with that link
    Then the client pairs and lists the environment
    And connects to it

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
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
