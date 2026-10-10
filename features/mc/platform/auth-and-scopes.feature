# Sources:
#   apps/server-ex/lib/hal_c2/auth.ex (pairing tokens, sessions, tickets, desktop bootstrap, access stream)
#   apps/server-ex/lib/hal_c2/web/router.ex (/oauth/token, /api/auth/*, with_scope)
#   apps/server-ex/lib/hal_c2/web/socket.ex (authAccess shape, current session)
#   apps/server-ex/lib/hal_c2/rpc.ex (the hal-c2.* socket twins of /api/auth/*)
#   apps/server-ex/lib/hal_c2/web.ex (the MC's access token)
#   apps/server-ex/lib/mix/tasks/hal_c2.pair.ex
#   apps/server-ex/test/hal_c2/scenarios_test.exs (access scenarios)
#   packages/contracts/src/auth.ts, environmentHttp.ts (AuthAccessStreamEvent, scope errors)
#   apps/server/src/auth/SessionStore.ts (WebSocketSessionRevokedError)
#   apps/server/src/auth/EnvironmentAuth.ts (client ordering, DPoP session lifetime, startup link hidden)
#   apps/server/src/auth/PairingGrantStore.ts (token alphabet and length, single use, key-bound grants)
#   apps/server/src/auth/dpop.ts (proof checks and replay)
#   apps/server/src/auth/http.ts (credential responses are no-store)
#   apps/server/src/auth/utils.ts (client metadata, per-port cookie name)
#   apps/server/src/cli/auth.ts, apps/server/src/cliAuthFormat.ts (hal-c2 auth pairing and session
#     commands: mint, list, revoke, JSON output, while the server is stopped)
#   apps/server/src/auth/RpcAuthorization.ts (scope each RPC needs)
#   docs/user/remote-access.md (Manage or revoke access)
#   docs/internals/environment-auth.md
#   docs/operations/development.md (Reusable dev credential)
#   AGENTS.md (npx hal-c2 pair, HAL_C2_DEV_AUTH_TOKEN)

Feature: MC authentication and scopes
  An MC issues its own sessions. Pairing hands out a session with a set of scopes, a
  session buys short-lived socket tickets, and administrators see and revoke access.

  Background:
    Given a running MC

  @mc
  Scenario: A pairing token is exchanged for a 30-day session
    Given a pairing token minted on the MC
    When a client exchanges it with its label, device type and OS
    Then the client receives a bearer access token that lasts 30 days
    And the grant lists the scopes it carries

  @mc
  Scenario: A pairing token works once
    Given a pairing token that a client already exchanged
    When another client exchanges it
    Then the exchange fails as an invalid grant

  @mc
  Scenario: A pairing token expires after five minutes
    Given a pairing token minted six minutes ago
    When a client exchanges it
    Then the exchange fails as an invalid grant

  @backlog @mc
  Scenario: Pairing tokens can be typed by hand
    When the MC mints a pairing token
    Then it is 12 characters long
    And it uses no characters that look alike, such as 0 and O or 1 and I

  @backlog @mc
  Scenario: Two clients racing for one pairing token leave exactly one session
    Given a pairing token that has not been exchanged
    When two clients exchange it at the same moment
    Then exactly one of them receives a session
    And the other is refused as an invalid grant

  @backlog @mc
  Scenario: A pairing link bound to a client key only pairs that client
    Given a pairing link minted for a client's DPoP key
    When a client that holds another key exchanges it
    Then the exchange is refused as an invalid grant
    And the client that holds the named key can still exchange it

  @mc
  Scenario: A pairing token is minted next to a running MC
    Given the MC is running
    When an operator mints a pairing link from the command line
    Then it prints a link with a one-time token for standard scopes
    And the running MC accepts it

  @mc
  Scenario Outline: Scopes granted by each kind of pairing
    When a client pairs with <credential>
    Then its session carries <scopes>

    Examples:
      | credential                   | scopes                                                                                |
      | a command-line pairing token | orchestration:read, orchestration:operate, terminal:operate, review:write, relay:read |
      | the desktop bootstrap token  | the standard scopes plus access:read, access:write and relay:write                    |
      | a pairing link naming scopes | only the named scopes the MC knows                                                    |

  @mc
  Scenario: The desktop bootstrap token can be exchanged repeatedly for a day
    Given the desktop app started the MC with a bootstrap token
    When its window exchanges the token again an hour later
    Then it receives another administrative session

  @mc
  Scenario: The desktop bootstrap token stops working a day after boot
    Given the MC booted more than 24 hours ago with a bootstrap token
    When the desktop app exchanges that token
    Then the exchange fails as an invalid grant

  @mc
  Scenario: A session buys a single-use socket ticket
    Given a client with a valid session
    When it asks for a socket ticket
    Then it receives a ticket valid for five minutes
    And the long-lived token never appears in the socket URL

  # The MC's access token (<data>/access-token) is readable only by the user the MC
  # runs as, so on HTTP it carries the same trust `?token=` has on the socket.
  @mc
  Scenario: Local tools authenticate over HTTP with the MC's access token
    Given a local tool that read the MC's access token
    When it asks the MC about its session with that token as a bearer
    Then the MC says it is authenticated with the administrative scopes
    And the tool can buy a socket ticket with that token
    And a socket opened with that ticket may do anything the MC's own token may

  @mc
  Scenario: The MC's access token is not a paired client
    Given a local tool bought a socket ticket with the MC's access token
    When an administrator lists the authorized clients
    Then the MC's access token is not among them

  @mc
  Scenario: A ticket request without a valid session is refused
    When a client asks for a socket ticket with an unknown bearer token
    Then the MC answers unauthorized

  @mc
  Scenario: A client reads its own session
    Given a client with a valid session
    When it asks the MC about its session
    Then the MC says it is authenticated with its scopes and expiry
    And without a credential the MC says it is not authenticated

  @mc
  Scenario: An expired session is refused
    Given a session that expired
    When the client asks for a socket ticket with it
    Then the MC answers unauthorized

  @mc
  Scenario Outline: Access management needs the right scope
    Given a client whose session lacks <scope>
    When it tries to <action>
    Then the MC refuses saying <scope> is required

    Examples:
      | scope        | action                            |
      | access:write | create a pairing link             |
      | access:read  | list pairing links                |
      | access:write | revoke a pairing link             |
      | access:read  | list authorized clients           |
      | access:write | revoke a client                   |
      | access:write | revoke every other client         |

  # The socket twins of /api/auth/*, for clients that hold a socket and no bearer.
  @mc
  Scenario Outline: Access management over the socket needs the same scope
    Given a device paired with standard scopes
    When it calls <method> on the MC
    Then only that call fails saying <scope> is required
    And the rest of its socket keeps working

    Examples:
      | method                    | scope        |
      | hal-c2.createPairingLink  | access:write |
      | hal-c2.pairingLinks       | access:read  |
      | hal-c2.revokePairingLink  | access:write |
      | hal-c2.clients            | access:read  |
      | hal-c2.revokeClient       | access:write |
      | hal-c2.revokeOtherClients | access:write |

  @mc
  Scenario: An administrator manages pairing links over the socket
    Given an administrator's socket
    When it creates a pairing link labelled "Tablet" through hal-c2.createPairingLink
    Then hal-c2.pairingLinks lists the link without its credential
    When it revokes the link through hal-c2.revokePairingLink
    Then hal-c2.pairingLinks no longer lists it
    And the revoked link no longer pairs

  @mc
  Scenario: An administrator manages paired clients over the socket
    Given an administrator's socket
    And two other paired clients
    Then hal-c2.clients marks the administrator's own session as current
    And hal-c2.revokeClient refuses the administrator's own session
    When it revokes one of the others through hal-c2.revokeClient
    And it revokes every other client through hal-c2.revokeOtherClients
    Then hal-c2.clients lists only the administrator's session

  # A session lives on the MC that paired it; on another member the caller has none, so
  # every session there would count as "other".
  @mc
  Scenario Outline: Paired clients are managed only on the MC the caller's session lives on
    Given an administrator's socket
    And two other paired clients
    And another member of the MC's cluster
    When the administrator calls <method> on that member
    Then the call is refused because the caller's session lives on another MC
    And no client was revoked

    Examples:
      | method                    |
      | hal-c2.clients            |
      | hal-c2.revokeClient       |
      | hal-c2.revokeOtherClients |

  @mc
  Scenario: Access requests without a bearer are refused as missing credentials
    When a client calls an access route without a bearer token
    Then the MC answers that a credential is missing

  @mc
  Scenario: A malformed access request is refused
    When an administrator sends an access request with an invalid body
    Then the MC answers that the request is invalid

  @mc
  Scenario: An administrator sees access changes live
    Given an administrator follows the MC's access list
    When a pairing link is created and then revoked
    And another device pairs
    Then each change arrives as it happens
    And the revoked link no longer pairs

  @mc
  Scenario: A standard session cannot follow the access list
    Given a device paired with standard scopes
    When it asks to follow the access list
    Then only that subscription fails saying access:read is required
    And the rest of its socket keeps working

  @mc
  Scenario: The access list marks the viewer's own session
    Given an administrator follows the MC's access list
    Then the administrator's own session is marked as current

  @mc
  Scenario: The access list shows which clients are connected
    Given an administrator follows the MC's access list
    When a paired device opens a socket
    Then that client shows as connected with its last connection time

  @backlog @mc
  Scenario: Paired clients are listed administrators first, then connected, then newest
    Given three paired clients, one of them an administrator
    And one of the others has an open socket
    When an administrator lists the authorized clients
    Then the administrator comes first
    And the connected client comes before the one that is not connected
    And clients that tie are listed newest first

  @backlog @mc
  Scenario: A client with an open socket stays listed past its expiry
    Given a paired client whose session has expired
    And it still has a socket open
    When an administrator lists the authorized clients
    Then the client is listed as connected
    And once its last socket closes it is no longer listed

  @backlog @mc
  Scenario: The MC's own startup link is not listed with pairing links
    Given the MC minted a link for the app that started it
    And an administrator created a pairing link labelled "Tablet"
    When an administrator lists pairing links
    Then only the "Tablet" link is listed

  @backlog @mc
  Scenario: A client's surface and app version are recorded when it connects
    Given a paired client
    When it opens a socket reporting its surface and app version
    Then the authorized clients list shows that surface and version for it
    And a later connection that reports only a version keeps the surface it reported before

  @backlog @mc
  Scenario Outline: A pairing link carries only scopes its creator holds
    Given an administrator creating a pairing link
    When it names <scopes>
    Then the MC <outcome>

    Examples:
      | scopes                                          | outcome                                    |
      | a scope that the administrator does not hold    | refuses the link as an invalid scope       |
      | no scopes at all                                | refuses the link as an invalid scope       |
      | the same scope twice                            | refuses the link as an invalid scope       |

  @backlog @mc
  Scenario: Responses that carry credentials are never cached
    When a client exchanges a pairing token or asks for a socket ticket
    Then the answer is marked as not storable by browsers or proxies

  @backlog @mc
  Scenario Outline: A call is refused when the session lacks the scope that matches what it changes
    Given a client whose session lacks <scope>
    When it <action>
    Then the MC refuses saying <scope> is required

    Examples:
      | scope                  | action                                         |
      | relay:write            | installs the relay client                      |
      | relay:read             | asks for the relay client's status             |
      | orchestration:operate  | reports the host's power state                 |
      | orchestration:read     | reports that the client is in the foreground   |
      | orchestration:operate  | submits a review on a pull request             |
      | orchestration:read     | previews a pull request                        |
      | review:write           | reads a review diff                            |
      | orchestration:operate  | opens a preview                                |
      | orchestration:read     | lists previews                                 |

  @mc
  Scenario: A client's device type is read from its user agent
    When a phone, a tablet and a desktop browser each pair
    Then the MC records each as mobile, tablet and desktop

  @backlog @mc
  Scenario: A client's own device description wins over its user agent
    When a client pairs presenting a device type, an operating system and a label
    Then the MC records what the client presented
    And only what it left out is read from the user agent

  @backlog @mc
  Scenario: The address a client paired from is recorded without IPv6 wrapping
    When a client pairs from an IPv4 address that the system reports as an IPv4-mapped IPv6 address
    Then the authorized clients list shows the plain IPv4 address

  @backlog @mc
  Scenario: A command-line tool is recorded as a bot
    When curl or wget exchanges a pairing token
    Then the MC records its device type as bot

  # hosted-web-app: only a browser keeps its session in a cookie, and two servers on one host
  # share cookies across ports, so the web app named its cookie after its port.
  @dropped @mc
  Scenario: Servers on one host keep their browser session cookies apart
    Given two MCs on one machine on different ports
    When a browser signs in to both
    Then each MC reads only the session cookie that it set

  @mc
  Scenario: Listed pairing links never reveal their secret
    Given an administrator created a pairing link
    When anyone lists pairing links
    Then the link is listed with its label, scopes and expiry
    And its credential is not in the listing

  @mc
  Scenario: An administrator cannot revoke the session they are using
    When an administrator revokes their own current session
    Then the MC refuses because the current session cannot be revoked

  @mc
  Scenario: Revoking every other client keeps the caller
    Given three paired clients
    When an administrator revokes every other client
    Then the other two sessions are revoked
    And the MC reports how many it revoked

  @mc
  Scenario: Sessions survive an MC restart
    Given a paired client
    When the MC restarts
    Then the client's session still works

  @mc
  Scenario: Auth records from an older MC gain their new fields
    Given an MC store written before client metadata was recorded
    When the MC starts
    Then its pairing and session records gain the missing fields
    And existing sessions keep working

  @mc
  Scenario: Every RPC requires the scope it declares
    Given a device paired without terminal:operate
    When it tries to write to a terminal
    Then the MC refuses saying terminal:operate is required

  @mc
  Scenario: Revoking a client closes the sockets it has open
    Given a paired client has an open socket
    When an administrator revokes that client
    Then the client's socket is closed as revoked
    And it cannot reconnect with its old session

  @mc
  Scenario: A token exchange can narrow the scopes it asks for
    Given a pairing link with administrative scopes
    When a client exchanges it asking only for orchestration:read
    Then its session carries only orchestration:read

  @mc
  Scenario: A token exchange asking for more than its link grants leaves the link unused
    Given a pairing link with standard scopes
    When a client exchanges it asking for access:write
    Then the exchange is refused as an invalid scope
    And the link still pairs a client that asks for what it grants

  @mc
  Scenario: A client proves possession of its key with DPoP
    Given a client that paired with a DPoP key
    When it presents its access token with a proof
    Then the MC accepts it
    And a token presented with an invalid proof is refused rather than treated as a bearer

  @backlog @mc
  Scenario: A session bound to a client key lasts one hour and is not a plain bearer
    Given a client that paired with a DPoP key
    Then its session expires after one hour, not thirty days
    And presenting that token as a plain bearer is refused
    And presenting a token that is not bound to a key under the DPoP scheme is refused

  @backlog @mc
  Scenario: A DPoP proof works once
    Given a client that paired with a DPoP key
    And it presented its token with a proof that the MC accepted
    When the same proof is presented again
    Then the MC refuses it as a replay

  @backlog @mc
  Scenario Outline: A DPoP proof that does not fit the request is refused for a reason
    Given a client that paired with a DPoP key
    When it presents a proof that <problem>
    Then the MC refuses it as <reason>

    Examples:
      | problem                                          | reason           |
      | was signed too long ago or in the future         | time_window      |
      | was signed by a key other than the paired one    | key_mismatch     |
      | names another method or address than the request | request_mismatch |
      | was made for a different access token            | token_mismatch   |
      | is not a well-formed proof                       | invalid_proof    |

  @mc
  Scenario: A reusable development credential signs in every worktree on one host
    Given a fixed development auth token is configured
    When a browser presents it to a development MC
    Then the MC grants an administrative session
    And revoking it locally does not affect another worktree

  @mc
  Scenario: The desktop's new bootstrap session replaces its previous one
    Given the desktop app exchanged its bootstrap token before a restart
    When it exchanges the new token after the restart
    Then the earlier desktop session is revoked in the same step

  @mc
  # The clients to list are paired first; the scenario named none.
  Scenario: A command-line tool lists and revokes access
    Given three paired clients
    When an operator lists sessions from the MC's command line
    Then it sees the same clients as Connections settings
    And it can revoke one of them

  @backlog @mc
  Scenario: A pairing link from the command line can carry a lifetime, a label and a public address
    When an operator mints a pairing link with a lifetime of one hour, the label "Ana's phone" and the public address "https://mc.example.com"
    Then the printed link points at "https://mc.example.com" and carries a one-time token
    And the link expires after one hour
    And Connections settings lists the link as "Ana's phone"

  @backlog @mc
  Scenario: An operator can print a minted pairing link as JSON
    When an operator mints a pairing link from the command line and asks for JSON
    Then the output is only a JSON document with the link's id, label, token, scopes and expiry

  @backlog @mc
  Scenario: A session token is issued from the command line for a headless client
    When an operator issues a session for the subject "ci" from the command line
    Then the MC prints a bearer token that signs in as a session for "ci"
    And the session has administrative scopes
    And the session is listed with the other clients and can be revoked

  @backlog @mc
  Scenario Outline: A session issued from the command line is printed the way the operator asked
    When an operator issues a session from the command line asking for <form>
    Then the output is <result>

    Examples:
      | form       | result                                                                         |
      | the token  | only the bearer token, so a script can capture it                              |
      | JSON       | only a JSON document with the session id, token, scopes, subject and expiry    |

  @backlog @mc
  Scenario: Pairing links listed from the command line show their details but never their secret
    Given two pairing links are waiting to be used
    When an operator lists pairing links from the command line
    Then each link shows its id, label, scopes and expiry
    And no link shows its token
    But the desktop's own bootstrap link is not listed

  @backlog @mc
  Scenario: Sessions listed from the command line show how each client is used
    Given a paired client that has never connected to the MC
    When an operator lists sessions from the command line
    Then the client shows its scopes, method, subject, issue time and expiry
    And its last connection reads "never"
    And a session with no client label reads "unlabeled client"
    And bearer tokens are never shown

  @backlog @mc
  Scenario Outline: Listing from the command line with nothing active says so
    Given there are no <things>
    When an operator lists <things> from the command line
    Then the output says "<message>"

    Examples:
      | things        | message                          |
      | pairing links | No active pairing credentials.   |
      | sessions      | No active sessions.              |

  @backlog @mc
  Scenario Outline: Revoking from the command line says whether anything was revoked
    Given <state>
    When an operator revokes it by id from the command line
    Then the output says <result>

    Examples:
      | state                                     | result                                       |
      | a pairing link waiting to be used         | the pairing credential was revoked           |
      | a pairing link that was already used      | no active pairing credential has that id     |
      | a paired client's session                 | the session was revoked                      |
      | a session that is already revoked         | no active session has that id                |

  @backlog @mc
  Scenario: Access can be managed from the command line while the MC is stopped
    Given the MC is not running
    When an operator mints a pairing link and lists sessions from the command line
    Then both commands work against the MC's stored access records
    And the minted link works once the MC starts
