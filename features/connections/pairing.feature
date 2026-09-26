# Sources:
#   docs/user/remote-access.md (Pair over a LAN or private network, Manage or revoke access)
#   docs/operations/development.md (vp run dev --share pairing URL, Reusable dev credential)
#   docs/internals/environment-auth.md (Authority survives transport changes)
#   apps/server-ex/lib/mix/tasks/t3.pair.ex
#   apps/server-ex/lib/t3/auth.ex, apps/server-ex/lib/t3/web/router.ex (/oauth/token, pairing links)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (Add environment, Create pairing link,
#     pairing link scopes, QR code, hosted app link, pairing code)
#   apps/web/src/components/settings/pairingUrls.ts
#   apps/web/src/components/auth/PairingRouteSurface.tsx
#   apps/mobile/src/features/connection/pairing.ts (host and code, QR payloads)
#   apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx
#   apps/desktop-qt/host/pairingUrl.ts (pairing URL announced by a server)
#   apps/tui/src/features.backlog.test.ts (environment-access-management)
#   docs/user/remote-access.md (t3 auth)
#   packages/contracts/src/auth.ts (pairing link, scopes)
#   Shared domain: tui/launch.feature holds pairing the terminal client from its command line;
#   mobile/pairing-and-environments.feature holds pairing from a phone;
#   settings/connections.feature holds creating, copying and revoking links on the desktop page.

Feature: Pairing a client with an environment
  Pairing turns a one-time link into a lasting session for one device. Links are minted on
  the host, carry a set of scopes, work once and expire after five minutes.

  Background:
    Given a running node

  @node
  Scenario: An operator prints a pairing link on the host
    When an operator asks the node for a pairing link with its LAN address
    Then it prints the address with a one-time token
    And the token grants standard scopes for five minutes

  @node
  Scenario: A pairing link names the address the operator gives it
    When an operator asks for a pairing link for "https://box.tailnet.ts.net"
    Then the printed link starts with that address

  @node
  Scenario: An administrator creates a labelled pairing link
    Given an administrator's client
    When it creates a pairing link labelled "Living room iPad" with standard scopes
    Then the node returns the link's credential once
    And the link is listed under that label until it is used

  @node
  Scenario: A used pairing link leaves the list
    Given a listed pairing link
    When a device pairs with it
    Then the link is no longer listed
    And the device is listed as a client

  @node
  Scenario: A revoked pairing link no longer pairs
    Given a listed pairing link
    When an administrator revokes it
    Then pairing with it fails

  @backlog @tui
  Scenario: The user pairs by pasting a pairing link
    Given a pairing link from another machine
    When the user adds an environment with that link
    Then the client pairs and lists the environment
    And connects to it

  @backlog @tui
  Scenario: The user pairs by entering a host and a pairing code
    When the user adds an environment with host "192.168.1.20:3780" and a pairing code
    Then the client pairs with that environment

  @backlog @tui
  Scenario: An expired or used pairing link explains itself
    Given a pairing link that already paired another device
    When the user adds an environment with it
    Then the client says the link is invalid or expired
    And asks for a fresh link

  @backlog @tui
  Scenario: An unreachable host fails pairing with a reason
    When the user pairs with a host that does not answer
    Then the client says the connection failed
    And offers the trace id for a bug report

  @backlog @desktop
  Scenario: A new pairing link can only be copied while its page is open
    Given the user created a pairing link
    When the user leaves the Connections page and comes back
    Then the link is listed without its secret
    And the user must create another link to share

  @backlog @shared
  Scenario: Pairing again with a fresh link replaces a lost session
    Given a device whose session was revoked
    When the user pairs it again with a fresh link
    Then it reconnects with a new session
    And keeps its local view of the environment

  @backlog @tui
  Scenario: The terminal client lists live access changes
    Given the user administers the environment
    When the user opens access management in the terminal client
    Then it lists pairing links and paired clients
    And updates the list when another client pairs

  @backlog @tui
  Scenario: The terminal client revokes one client
    Given another paired client
    When the user revokes it from the terminal client
    Then that client can no longer connect

  @backlog @tui
  Scenario: The terminal client revokes every other client
    Given three other paired clients
    When the user revokes every other client
    Then only the terminal client's own session remains

  # The hosted app.t3.codes pairing link. hal-c2 has no hosted web app; QML clients pair
  # with the node's own link.
  @dropped @desktop
  Scenario: The user copies a hosted app pairing link
    Given the environment is reachable over HTTPS
    When the user copies the hosted app link
    Then a browser can pair through app.t3.codes without installing anything
