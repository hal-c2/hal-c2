# Sources:
#   apps/server-ex/lib/t3/web/router.ex (CORS, /.well-known/t3/environment, GET /, /mcp,
#     /api/pull-requests/diff, 404 fallback)
#   apps/server-ex/test/t3/features_backlog_test.exs (hosted-web-app)
#   apps/server/src/http.ts (static web app, browser session)
#   apps/web/src/environments/primary/auth.ts
#   apps/web/src/hostedPairing.ts
#   docs/internals/remote.md (Hosted web is a client)
#   docs/user/remote-access.md (Hosted web app)
#   docs/user/install.md

Feature: The node's HTTP surface and what it hosts
  Besides the WebSocket, a node answers a small set of HTTP routes: discovery, pairing,
  agents' MCP, pull request diffs and signed files. It does not host the web app.

  Background:
    Given a running node

  @node
  Scenario: Any origin may call the node's HTTP routes
    When a browser on another origin sends a preflight request
    Then the node answers it with no content and allows the request

  @node
  Scenario: Discovery describes the environment without credentials
    When anyone asks the node's well-known environment route
    Then it answers with the environment descriptor and node name
    And the list of cluster members

  @node
  Scenario: Opening the node's address in a browser explains pairing
    When a browser opens the node's root address
    Then it shows how to paste a pairing link into Add environment
    And says links work once and expire after five minutes

  @node
  Scenario: Unknown routes are not found
    When a client requests a route the node does not have
    Then the node answers not found

  @node
  Scenario: Agents reach the node's MCP server with their own bearer
    Given a thread's agent with its MCP bearer
    When the agent posts an MCP request
    Then the node answers it on the same request

  @node
  Scenario: The MCP route has no server-initiated stream
    When an agent opens the MCP route for streaming
    Then the node answers that the method is not allowed
    And ending an MCP session always succeeds

  @node
  Scenario: A pull request diff is fetched over HTTP on the project's node
    Given a client with orchestration:read
    When it asks for a pull request's diff over HTTP
    Then the project's node answers with the diff

  @node
  Scenario Outline: Pull request diffs that cannot be fetched
    Given a client with orchestration:read
    When it asks for a pull request diff and <problem>
    Then the node answers <status>

    Examples:
      | problem                                   | status                  |
      | the pull request provider is unavailable  | service unavailable     |
      | fetching the diff fails                   | bad gateway             |

  # hosted-web-app: the node serves the QML client bundle for the desktop and mobile
  # clients' downloadable overlay, so a thin client can load its UI from the node it pairs with.
  @backlog @node
  Scenario: The node serves the QML client bundle
    Given a QML client that pairs with the node
    When it asks the node for its client bundle
    Then the node serves the bundle matching its version

  @backlog @mobile
  Scenario: The mobile client loads its QML overlay from the node
    Given the mobile client paired with a node of a newer version
    When it connects
    Then it loads the matching QML overlay from that node

  # hosted-web-app: hal-c2 has no web app. apps/web is going away; QML clients replace it,
  # so the node does not serve the web bundle or the browser pages that bootstrap it.
  @dropped @node
  Scenario: The node serves the web app at its origin
    Given a node started for a local browser
    When the browser opens the node's origin
    Then it loads the T3 Code web app instead of the pairing help page

  # hosted-web-app: browser cookies exist only to serve the web app.
  @dropped @node
  Scenario: The web app's bootstrap credential sets a browser session cookie
    Given the web app served by the node
    When it exchanges its bootstrap credential
    Then the node sets a browser session cookie
    And the app connects without pairing

  # hosted-web-app: with no browser sessions there is nothing to revoke by cookie.
  @dropped @node
  Scenario: A revoked browser session is refused
    Given a browser session
    When the user revokes that client from Connections
    Then the browser's next request is refused

  # The hosted app.t3.codes pairing page carries the secret in the URL fragment. hal-c2
  # clients paste or scan the node's own pairing link instead.
  @dropped @node
  Scenario: A hosted pairing link keeps its secret out of the hosted origin
    Given a hosted pairing link for a node
    When a browser opens it
    Then the secret is exchanged directly with the node
    And it is removed from the browser history
