# Sources:
#   apps/server-ex/lib/hal_c2/web/router.ex (CORS, /.well-known/hal-c2/environment, GET /, /mcp,
#     /api/pull-requests/diff, 404 fallback)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (hosted-web-app)
#   apps/server/src/http.ts (static web app, browser session)
#   apps/server/src/httpResponseErrorGuard.ts (a client that hangs up mid-response)
#   apps/server/src/orchestration-v2/http.ts, packages/contracts/src/environmentHttp.ts
#     (/api/orchestration shell and thread snapshots, history pages)
#   apps/web/src/environments/primary/auth.ts
#   apps/web/src/hostedPairing.ts
#   docs/internals/remote.md (Hosted web is a client)
#   docs/user/remote-access.md (Hosted web app)
#   docs/user/install.md

Feature: The MC's HTTP surface and what it hosts
  Besides the WebSocket, an MC answers a small set of HTTP routes: discovery, pairing,
  agents' MCP, pull request diffs and signed files. It does not host the web app.

  Background:
    Given a running MC

  @mc
  Scenario: Any origin may call the MC's HTTP routes
    When a browser on another origin sends a preflight request
    Then the MC answers it with no content and allows the request

  @mc
  Scenario: Discovery describes the environment without credentials
    When anyone asks the MC's well-known environment route
    Then it answers with the environment descriptor and MC name
    And the list of cluster members

  @mc
  Scenario: Opening the MC's address in a browser explains pairing
    When a browser opens the MC's root address
    Then it shows how to paste a pairing link into Add environment
    And says links work once and expire after five minutes

  @mc
  Scenario: Unknown routes are not found
    When a client requests a route the MC does not have
    Then the MC answers not found

  @mc
  Scenario: Agents reach the MC's MCP server with their own bearer
    Given a thread's agent with its MCP bearer
    When the agent posts an MCP request
    Then the MC answers it on the same request

  @mc
  Scenario: The MCP route has no server-initiated stream
    When an agent opens the MCP route for streaming
    Then the MC answers that the method is not allowed
    And ending an MCP session always succeeds

  @mc
  Scenario: A pull request diff is fetched over HTTP on the project's MC
    Given a client with orchestration:read
    When it asks for a pull request's diff over HTTP
    Then the project's MC answers with the diff

  @mc
  Scenario Outline: Pull request diffs that cannot be fetched
    Given a client with orchestration:read
    When it asks for a pull request diff and <problem>
    Then the MC answers <status>

    Examples:
      | problem                                   | status                  |
      | the pull request provider is unavailable  | service unavailable     |
      | fetching the diff fails                   | bad gateway             |

  @mc @backlog
  Scenario: A client loads the shell snapshot over HTTP and then follows the socket
    Given a client with orchestration:read
    When it asks for "/api/orchestration/shell"
    Then it receives every project and active thread row with the sequence they are at
    And subscribing to the shell after that sequence sends only what changed since

  @mc @backlog
  Scenario: The HTTP shell snapshot does not wait for repository lookups
    Given a project whose repository identity is still being looked up
    When a client asks for the shell snapshot over HTTP
    Then the answer comes at once with that project's repository left empty
    And the repository arrives later over the socket

  @mc @backlog
  Scenario Outline: A client loads a thread over HTTP
    Given a client with orchestration:read
    When it asks for "<route>" of an existing thread
    Then it receives <answer> and the sequence it is at

    Examples:
      | route                                        | answer                                                     |
      | /api/orchestration/threads/:threadId         | the whole thread                                           |
      | /api/orchestration/threads/:threadId/bounded | its newest turns, a history cursor and whether more exists |
      | /api/orchestration/threads/:threadId/history | the page of turns before the cursor it sent                |

  @mc @backlog
  Scenario Outline: Orchestration snapshots that cannot be served over HTTP
    When a client asks for a thread over HTTP and <problem>
    Then the MC answers <status> with reason "<reason>"

    Examples:
      | problem                                   | status          | reason                 |
      | the thread does not exist                 | not found       | thread_not_found       |
      | its history cursor is not one the MC gave | invalid request | invalid_history_cursor |

  @mc @backlog
  Scenario: Orchestration snapshots over HTTP need the read scope
    Given a client without orchestration:read
    When it asks for the shell snapshot or a thread over HTTP
    Then the MC refuses the request

  # hosted-web-app: the MC serves the QML client bundle for the desktop and mobile
  # clients' downloadable overlay, so a thin client can load its UI from the MC it pairs with.
  @backlog @mc
  Scenario: The MC serves the QML client bundle
    Given a QML client that pairs with the MC
    When it asks the MC for its client bundle
    Then the MC serves the bundle matching its version

  @backlog @mobile
  Scenario: The mobile client loads its QML overlay from the MC
    Given the mobile client paired with an MC of a newer version
    When it connects
    Then it loads the matching QML overlay from that MC

  # hosted-web-app: HAL-C2 has no web app. apps/web is going away; QML clients replace it,
  # so the MC does not serve the web bundle or the browser pages that bootstrap it.
  @dropped @mc
  Scenario: The MC serves the web app at its origin
    Given an MC started for a local browser
    When the browser opens the MC's origin
    Then it loads the HAL-C2 web app instead of the pairing help page

  # hosted-web-app: browser cookies exist only to serve the web app.
  @dropped @mc
  Scenario: The web app's bootstrap credential sets a browser session cookie
    Given the web app served by the MC
    When it exchanges its bootstrap credential
    Then the MC sets a browser session cookie
    And the app connects without pairing

  # hosted-web-app: with no browser sessions there is nothing to revoke by cookie.
  @dropped @mc
  Scenario: A revoked browser session is refused
    Given a browser session
    When the user revokes that client from Connections
    Then the browser's next request is refused

  # The hosted app.hal-c2.example pairing page carries the secret in the URL fragment. HAL-C2
  # clients paste or scan the MC's own pairing link instead.
  @dropped @mc
  Scenario: A hosted pairing link keeps its secret out of the hosted origin
    Given a hosted pairing link for an MC
    When a browser opens it
    Then the secret is exchanged directly with the MC
    And it is removed from the browser history

  @backlog @mc
  Scenario: A client that hangs up mid-response does not take the MC down
    Given a client is receiving a large response or a socket upgrade
    When the client disconnects before the MC finishes writing
    Then the MC drops that connection
    And every other client keeps being served
