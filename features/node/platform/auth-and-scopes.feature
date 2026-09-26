# Sources:
#   apps/server-ex/lib/t3/auth.ex (pairing tokens, sessions, tickets, desktop bootstrap, access stream)
#   apps/server-ex/lib/t3/web/router.ex (/oauth/token, /api/auth/*, with_scope)
#   apps/server-ex/lib/t3/web/socket.ex (authAccess shape, current session)
#   apps/server-ex/lib/mix/tasks/t3.pair.ex
#   apps/server-ex/test/t3/scenarios_test.exs (access scenarios)
#   packages/contracts/src/auth.ts, environmentHttp.ts (AuthAccessStreamEvent, scope errors)
#   apps/server/src/auth/SessionStore.ts (WebSocketSessionRevokedError)
#   docs/user/remote-access.md (Manage or revoke access)
#   docs/internals/environment-auth.md
#   docs/operations/development.md (Reusable dev credential)
#   AGENTS.md (npx t3 pair, T3CODE_DEV_AUTH_TOKEN)

Feature: Node authentication and scopes
  A node issues its own sessions. Pairing hands out a session with a set of scopes, a
  session buys short-lived socket tickets, and administrators see and revoke access.

  Background:
    Given a running node

  @node
  Scenario: A pairing token is exchanged for a 30-day session
    Given a pairing token minted on the node
    When a client exchanges it with its label, device type and OS
    Then the client receives a bearer access token that lasts 30 days
    And the grant lists the scopes it carries

  @node
  Scenario: A pairing token works once
    Given a pairing token that a client already exchanged
    When another client exchanges it
    Then the exchange fails as an invalid grant

  @node
  Scenario: A pairing token expires after five minutes
    Given a pairing token minted six minutes ago
    When a client exchanges it
    Then the exchange fails as an invalid grant

  @node
  Scenario: A pairing token is minted next to a running node
    Given the node is running
    When an operator mints a pairing link from the command line
    Then it prints a link with a one-time token for standard scopes
    And the running node accepts it

  @node
  Scenario Outline: Scopes granted by each kind of pairing
    When a client pairs with <credential>
    Then its session carries <scopes>

    Examples:
      | credential                     | scopes                                                                                                   |
      | a command-line pairing token   | orchestration:read, orchestration:operate, terminal:operate, review:write, relay:read                    |
      | the desktop bootstrap token    | the standard scopes plus access:read, access:write and relay:write                                       |
      | a pairing link naming scopes   | only the named scopes the node knows                                                                     |

  @node
  Scenario: The desktop bootstrap token can be exchanged repeatedly for a day
    Given the desktop app started the node with a bootstrap token
    When its window exchanges the token again an hour later
    Then it receives another administrative session

  @node
  Scenario: The desktop bootstrap token stops working a day after boot
    Given the node booted more than 24 hours ago with a bootstrap token
    When the desktop app exchanges that token
    Then the exchange fails as an invalid grant

  @node
  Scenario: A session buys a single-use socket ticket
    Given a client with a valid session
    When it asks for a socket ticket
    Then it receives a ticket valid for five minutes
    And the long-lived token never appears in the socket URL

  @node
  Scenario: A ticket request without a valid session is refused
    When a client asks for a socket ticket with an unknown bearer token
    Then the node answers unauthorized

  @node
  Scenario: A client reads its own session
    Given a client with a valid session
    When it asks the node about its session
    Then the node says it is authenticated with its scopes and expiry
    And without a credential the node says it is not authenticated

  @node
  Scenario: An expired session is refused
    Given a session that expired
    When the client asks for a socket ticket with it
    Then the node answers unauthorized

  @node
  Scenario Outline: Access management needs the right scope
    Given a client whose session lacks <scope>
    When it tries to <action>
    Then the node refuses saying <scope> is required

    Examples:
      | scope        | action                            |
      | access:write | create a pairing link             |
      | access:read  | list pairing links                |
      | access:write | revoke a pairing link             |
      | access:read  | list authorized clients           |
      | access:write | revoke a client                   |
      | access:write | revoke every other client         |

  @node
  Scenario: Access requests without a bearer are refused as missing credentials
    When a client calls an access route without a bearer token
    Then the node answers that a credential is missing

  @node
  Scenario: A malformed access request is refused
    When an administrator sends an access request with an invalid body
    Then the node answers that the request is invalid

  @node
  Scenario: An administrator sees access changes live
    Given an administrator follows the node's access list
    When a pairing link is created and then revoked
    And another device pairs
    Then each change arrives as it happens
    And the revoked link no longer pairs

  @node
  Scenario: A standard session cannot follow the access list
    Given a device paired with standard scopes
    When it asks to follow the access list
    Then only that subscription fails saying access:read is required
    And the rest of its socket keeps working

  @node
  Scenario: The access list marks the viewer's own session
    Given an administrator follows the node's access list
    Then the administrator's own session is marked as current

  @node
  Scenario: The access list shows which clients are connected
    Given an administrator follows the node's access list
    When a paired device opens a socket
    Then that client shows as connected with its last connection time

  @node
  Scenario: A client's device type is read from its user agent
    When a phone, a tablet and a desktop browser each pair
    Then the node records each as mobile, tablet and desktop

  @node
  Scenario: Listed pairing links never reveal their secret
    Given an administrator created a pairing link
    When anyone lists pairing links
    Then the link is listed with its label, scopes and expiry
    And its credential is not in the listing

  @node
  Scenario: An administrator cannot revoke the session they are using
    When an administrator revokes their own current session
    Then the node refuses because the current session cannot be revoked

  @node
  Scenario: Revoking every other client keeps the caller
    Given three paired clients
    When an administrator revokes every other client
    Then the other two sessions are revoked
    And the node reports how many it revoked

  @node
  Scenario: Sessions survive a node restart
    Given a paired client
    When the node restarts
    Then the client's session still works

  @node
  Scenario: Auth records from an older node gain their new fields
    Given a node store written before client metadata was recorded
    When the node starts
    Then its pairing and session records gain the missing fields
    And existing sessions keep working

  @backlog @node
  Scenario: Every RPC requires the scope it declares
    Given a device paired without terminal:operate
    When it tries to write to a terminal
    Then the node refuses saying terminal:operate is required

  # The node deletes the session record, so the next ticket fails, but sockets already open
  # stay connected until they drop.
  @backlog @node
  Scenario: Revoking a client closes the sockets it has open
    Given a paired client has an open socket
    When an administrator revokes that client
    Then the client's socket is closed as revoked
    And it cannot reconnect with its old session

  @backlog @node
  Scenario: A token exchange can narrow the scopes it asks for
    Given a pairing link with administrative scopes
    When a client exchanges it asking only for orchestration:read
    Then its session carries only orchestration:read

  @backlog @node
  Scenario: A client proves possession of its key with DPoP
    Given a client that paired with a DPoP key
    When it presents its access token with a proof
    Then the node accepts it
    And a token presented with an invalid proof is refused rather than treated as a bearer

  @backlog @node
  Scenario: A reusable development credential signs in every worktree on one host
    Given a fixed development auth token is configured
    When a browser presents it to a development node
    Then the node grants an administrative session
    And revoking it locally does not affect another worktree

  @backlog @node
  Scenario: The desktop's new bootstrap session replaces its previous one
    Given the desktop app exchanged its bootstrap token before a restart
    When it exchanges the new token after the restart
    Then the earlier desktop session is revoked in the same step

  @backlog @node
  Scenario: A command-line tool lists and revokes access
    When an operator lists sessions from the node's command line
    Then it sees the same clients as Connections settings
    And it can revoke one of them
