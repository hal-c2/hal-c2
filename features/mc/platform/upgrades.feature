# Sources:
#   apps/server-ex/lib/hal_c2/upgrade.ex (plan, hot load, restart with exit 75, outcome)
#   apps/server-ex/lib/hal_c2/upgrade/source.ex (cache, cluster peer, release URL, SHA-256)
#   apps/server-ex/lib/hal_c2/upgrade/code.ex (a code-only version's release, on the running runtime)
#   apps/server-ex/lib/hal_c2/hot.ex (md5 skip, code_change, soft purge, lingering modules)
#   apps/server-ex/lib/mix/tasks/hal_c2.upgrade.ex, hal_c2.bundle.ex
#   apps/server-ex/lib/hal_c2/web/router.ex (GET /api/upgrade/:token, POST /api/dev/reload)
#   mise-tasks/mc/reload
#   apps/server-ex/lib/hal_c2/web/socket.ex (serverUpdate shape, config.ready updateOutcome, @state_version)
#   apps/server-ex/rel/overlays/bin/hal-c2-service
#   packages/contracts/src/server.ts (server.updateServer, server.updateServerWithProgress, server.commitDesktopUpdate)
#   docs/internals/server-updates.md
#   docs/user/updating.md
#   docs/user/background-service.md (hal-c2 update, channels)

Feature: MC self-update and hot upgrades
  An MC moves to another version in place when the change allows, and restarts into it
  under its service wrapper when it does not. Clients see progress and learn the outcome.

  Background:
    Given an MC running from a release under the service wrapper

  @mc
  Scenario: A code-only update loads in place without dropping anyone
    Given a bundle whose changes are only ordinary modules
    When a client asks the MC to update to that version
    Then the MC loads the changed modules in place
    And open sockets and provider sessions stay up
    And the MC reports the new version

  @mc
  Scenario: Update progress streams to the client that asked
    When a client asks the MC to update with progress
    Then it sees downloading, then installing, then complete
    And the progress stream ends

  @mc
  Scenario Outline: Changes that need a restart restart into the new version
    Given a bundle that changes <what>
    When a client asks the MC to update to it
    Then the MC installs the bundle
    And exits asking its service wrapper to start it again
    And it boots into the new version

    Examples:
      | what                       |
      | the OTP release            |
      | a dependency               |
      | the set of dependencies    |
      | the platform's packages    |
      | the configuration          |
      | a supervisor module        |

  @mc
  Scenario: A code-only update keeps the Erlang runtime the MC runs
    Given a code-only bundle built with another patch of the Erlang runtime
    When a client asks the MC to update to it
    Then the MC loads the changed modules in place
    And its next start uses the Erlang runtime it already has

  @mc
  Scenario: A code-only update loads from a bundle built for another platform
    Given the only bundle at hand is another platform's, changing only code
    When a client asks the MC to update to it
    Then the MC loads the changed modules in place
    And the MC reports the new version

  @mc
  Scenario: An update that needs a restart is refused from another platform's bundle
    Given the only bundle at hand is another platform's, needing a restart
    When a client asks the MC to update to it
    Then the update fails saying a restart takes this platform's release

  @mc
  Scenario: An MC not started by the service wrapper refuses a restart update
    Given an MC started directly from a release
    And a bundle that needs a restart
    When a client asks the MC to update
    Then the update fails saying the MC was not started by the service wrapper

  @mc
  Scenario: A failed hot load falls back to a restart
    Given a code-only bundle that fails to load in place
    When a client asks the MC to update to it
    Then the MC restarts into the new version instead

  @mc
  Scenario: The outcome of the last update is reported when clients reconnect
    Given the MC restarted into a new version
    When a client reconnects
    Then the ready it receives says the update was committed

  @mc
  Scenario: An update that booted the wrong version is reported as rolled back
    Given the MC was restarting into a new version
    And it booted the old version instead
    When a client reconnects
    Then the ready it receives says the update was rolled back and why

  @mc
  Scenario: Clients watching an MC see its new version after an in-place update
    Given a client follows the MC's config
    When the MC loads a new version in place
    Then the client receives a new ready with the MC's new descriptor

  @mc
  Scenario: Only one update runs at a time
    Given an update is in progress
    When another client asks the MC to update
    Then the second request does not start another update

  @mc
  Scenario Outline: Update requests the MC refuses
    Given <situation>
    When a client asks the MC to update
    Then the update fails saying "<reason>"

    Examples:
      | situation                                | reason                      |
      | the MC runs from a checkout              | runs from a checkout        |
      | the requested version is the running one | already runs                |
      | no target version is given               | No target version was given |

  @mc
  Scenario: A bundle is taken from the MC's own cache first
    Given the MC already downloaded the target version
    When it updates to that version
    Then it does not download it again

  @mc
  Scenario: A clustered MC fetches the bundle from a peer
    Given a peer in the cluster holds the target bundle
    When the MC updates to that version
    Then it fetches the bundle from the peer over a one-time link
    And the link cannot be used twice

  @mc
  Scenario: An MC downloads the bundle from the release URL when nobody has it
    Given no cache or peer holds the target bundle
    When the MC updates
    Then it downloads the bundle for its platform from the release location

  @mc
  Scenario: A bundle that does not match its checksum is refused
    Given a downloaded bundle whose SHA-256 does not match
    When the MC updates
    Then the update fails saying the bundle does not match its checksum
    And the running version is unchanged

  @mc
  Scenario: The bundle location can be overridden
    Given HAL_C2_UPGRADE_URL points to a private mirror
    When the MC downloads a bundle
    Then it downloads from the mirror

  @mc
  Scenario: A maintainer rolls a release out to several MCs
    When a maintainer upgrades three MCs from a checkout
    Then the first MC receives the bundle
    # Each MC takes the bundle from whichever peer offers it first, not only the first MC.
    And the other two fetch it from a peer that already has it

  @mc
  Scenario: A developer reloads changed modules into running MCs
    Given MCs started from a checkout
    When a developer reloads them after editing code
    Then only modules whose code changed are loaded
    And the report lists modules that need a restart

  @mc
  Scenario: A developer reloads the MC their checkout runs without naming it
    Given MCs started from a checkout
    When a developer reloads the local MC with its own access token
    Then only modules whose code changed are loaded
    And the report lists modules that need a restart

  @mc
  Scenario: A developer reloads the MC from a checkout it was not started from
    Given another checkout holds edited code the MC was not started from
    When a developer reloads the local MC from that checkout
    Then only modules whose code changed are loaded
    And the report lists modules that need a restart

  @mc
  Scenario: A reload from a directory without a build is refused
    Given MCs started from a checkout
    When a developer reloads the local MC from a directory with no build
    Then the developer is told it holds no compiled MC

  @mc
  Scenario: A developer moves the installed MC to a bundle built on its machine
    Given a bundle on this machine the MC has not seen
    When a developer reloads the local MC with that bundle
    Then the MC loads the changed modules in place
    And the MC reports the new version

  @mc
  Scenario: A bundle built on its machine that needs a restart restarts the installed MC
    Given a bundle on this machine the MC has not seen that needs a restart
    When a developer reloads the local MC with that bundle
    Then the MC restarts into the new version instead

  @mc
  Scenario: Only the MC's own access token reloads it
    Given MCs started from a checkout
    When someone asks the local MC to reload with another token
    Then the MC refuses and loads nothing

  @mc
  Scenario: Modules still in use are left for later rather than killed
    Given a process is blocked inside a module being replaced
    When new code loads
    Then that module is reported as lingering
    And the process is not killed

  @mc
  Scenario: Socket state from an older version is migrated at its next message
    Given a client connected before an in-place update
    When the socket handles its next frame
    Then its state is migrated to the new version's shape

  @mc
  Scenario: A release MC advertises that it can update itself
    When a client reads the descriptor of an MC running from a release
    Then it offers in-place self-update
    And an MC running from a checkout does not

  @backlog @mc
  Scenario: An MC tells clients a newer version is available on its channel
    Given a newer MC release is published on the MC's channel
    When a client follows the MC's config
    Then it learns which version is available

  @backlog @mc
  Scenario: An operator updates the MC from its command line
    When an operator asks the MC's command line to update to the newest release
    Then the MC updates as it would for a client
    And the command asks before interrupting running turns

  @backlog @mc
  Scenario: A failed restart returns to the previous version
    Given a restart into a new version fails before it is ready
    Then the service wrapper starts the previous version again
    And the database is restored to its state before the trial

  # Desktop-app two-phase update handoff. An MC updates itself in place or restarts under
  # bin/hal-c2-service; the Electron app's bundled backend is not how HAL-C2 ships the MC.
  @dropped @mc
  Scenario: The desktop app commits a prepared update after reconnecting
    Given the desktop app prepared an update and received a token
    When it commits that token
    Then its bundled server restarts into the new version
