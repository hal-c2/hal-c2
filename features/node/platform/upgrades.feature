# Sources:
#   apps/server-ex/lib/t3/upgrade.ex (plan, hot load, restart with exit 75, outcome)
#   apps/server-ex/lib/t3/upgrade/source.ex (cache, cluster peer, release URL, SHA-256)
#   apps/server-ex/lib/t3/hot.ex (md5 skip, code_change, soft purge, lingering modules)
#   apps/server-ex/lib/mix/tasks/t3.upgrade.ex, t3.bundle.ex
#   apps/server-ex/lib/t3/web/router.ex (GET /api/upgrade/:token)
#   apps/server-ex/lib/t3/web/socket.ex (serverUpdate shape, config.ready updateOutcome, @state_version)
#   apps/server-ex/rel/overlays/bin/t3-service
#   packages/contracts/src/server.ts (server.updateServer, server.updateServerWithProgress, server.commitDesktopUpdate)
#   docs/internals/server-updates.md
#   docs/user/updating.md
#   docs/user/background-service.md (t3 update, channels)

Feature: Node self-update and hot upgrades
  A node moves to another version in place when the change allows, and restarts into it
  under its service wrapper when it does not. Clients see progress and learn the outcome.

  Background:
    Given a node running from a release under the service wrapper

  @node
  Scenario: A code-only update loads in place without dropping anyone
    Given a bundle whose changes are only ordinary modules
    When a client asks the node to update to that version
    Then the node loads the changed modules in place
    And open sockets and provider sessions stay up
    And the node reports the new version

  @node
  Scenario: Update progress streams to the client that asked
    When a client asks the node to update with progress
    Then it sees downloading, then installing, then complete
    And the progress stream ends

  @node
  Scenario Outline: Changes that need a restart restart into the new version
    Given a bundle that changes <what>
    When a client asks the node to update to it
    Then the node installs the bundle
    And exits asking its service wrapper to start it again
    And it boots into the new version

    Examples:
      | what                       |
      | the Erlang runtime         |
      | the OTP release            |
      | the set of applications    |
      | a native library           |
      | the configuration          |
      | a supervisor module        |

  @node
  Scenario: A node not started by the service wrapper refuses a restart update
    Given a node started directly from a release
    And a bundle that needs a restart
    When a client asks the node to update
    Then the update fails saying the node was not started by the service wrapper

  @node
  Scenario: A failed hot load falls back to a restart
    Given a code-only bundle that fails to load in place
    When a client asks the node to update to it
    Then the node restarts into the new version instead

  @node
  Scenario: The outcome of the last update is reported when clients reconnect
    Given the node restarted into a new version
    When a client reconnects
    Then the ready it receives says the update was committed

  @node
  Scenario: An update that booted the wrong version is reported as rolled back
    Given the node was restarting into a new version
    And it booted the old version instead
    When a client reconnects
    Then the ready it receives says the update was rolled back and why

  @node
  Scenario: Clients watching a node see its new version after an in-place update
    Given a client follows the node's config
    When the node loads a new version in place
    Then the client receives a new ready with the node's new descriptor

  @node
  Scenario: Only one update runs at a time
    Given an update is in progress
    When another client asks the node to update
    Then the second request does not start another update

  @node
  Scenario Outline: Update requests the node refuses
    Given <situation>
    When a client asks the node to update
    Then the update fails saying "<reason>"

    Examples:
      | situation                                 | reason                                   |
      | the node runs from a checkout             | runs from a checkout                     |
      | the requested version is the running one  | already runs                             |
      | no target version is given                | No target version was given              |

  @node
  Scenario: A bundle is taken from the node's own cache first
    Given the node already downloaded the target version
    When it updates to that version
    Then it does not download it again

  @node
  Scenario: A clustered node fetches the bundle from a peer
    Given a peer in the cluster holds the target bundle
    When the node updates to that version
    Then it fetches the bundle from the peer over a one-time link
    And the link cannot be used twice

  @node
  Scenario: A node downloads the bundle from the release URL when nobody has it
    Given no cache or peer holds the target bundle
    When the node updates
    Then it downloads the bundle for its platform from the release location

  @node
  Scenario: A bundle that does not match its checksum is refused
    Given a downloaded bundle whose SHA-256 does not match
    When the node updates
    Then the update fails saying the bundle does not match its checksum
    And the running version is unchanged

  @node
  Scenario: The bundle location can be overridden
    Given T3_UPGRADE_URL points to a private mirror
    When the node downloads a bundle
    Then it downloads from the mirror

  @node
  Scenario: A maintainer rolls a release out to several nodes
    When a maintainer upgrades three nodes from a checkout
    Then the first node receives the bundle
    # Each node takes the bundle from whichever peer offers it first, not only the first node.
    And the other two fetch it from a peer that already has it

  @node
  Scenario: A developer reloads changed modules into running nodes
    Given nodes started from a checkout
    When a developer reloads them after editing code
    Then only modules whose code changed are loaded
    And the report lists modules that need a restart

  @node
  Scenario: Modules still in use are left for later rather than killed
    Given a process is blocked inside a module being replaced
    When new code loads
    Then that module is reported as lingering
    And the process is not killed

  @node
  Scenario: Socket state from an older version is migrated at its next message
    Given a client connected before an in-place update
    When the socket handles its next frame
    Then its state is migrated to the new version's shape

  @node
  Scenario: A release node advertises that it can update itself
    When a client reads the descriptor of a node running from a release
    Then it offers in-place self-update
    And a node running from a checkout does not

  @backlog @node
  Scenario: A node tells clients a newer version is available on its channel
    Given a newer node release is published on the node's channel
    When a client follows the node's config
    Then it learns which version is available

  @backlog @node
  Scenario: An operator updates the node from its command line
    When an operator asks the node's command line to update to the newest release
    Then the node updates as it would for a client
    And the command asks before interrupting running turns

  @backlog @node
  Scenario: A failed restart returns to the previous version
    Given a restart into a new version fails before it is ready
    Then the service wrapper starts the previous version again
    And the database is restored to its state before the trial

  # Desktop-app two-phase update handoff. A node updates itself in place or restarts under
  # bin/t3-service; the Electron app's bundled backend is not how hal-c2 ships the node.
  @dropped @node
  Scenario: The desktop app commits a prepared update after reconnecting
    Given the desktop app prepared an update and received a token
    When it commits that token
    Then its bundled server restarts into the new version
