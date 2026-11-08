# Sources:
#   https://github.com/pingdotgg/t3code/pull/19649
#   https://github.com/pingdotgg/t3code/pull/23113
#   https://github.com/pingdotgg/t3code/pull/19311 (dropped)
#   https://github.com/pingdotgg/t3code/pull/22253
#   https://github.com/pingdotgg/t3code/pull/29464 (dropped)
#   apps/server-ex/lib/hal_c2/upgrade.ex (plan, release upgrade, restart with exit 75, outcome)
#   apps/server-ex/lib/hal_c2/upgrade/release.ex (release_handler: unpack, relup, install, permanent, rollback, NIFs)
#   apps/server-ex/lib/hal_c2/upgrade/appup.ex (appups from the release diff: code_change, soft purge)
#   apps/server-ex/lib/hal_c2/upgrade/tree.ex (services a new release adds, changes or drops)
#   apps/server-ex/lib/hal_c2/upgrade/dev.ex (a checkout's build as a release upgrade)
#   apps/server-ex/lib/hal_c2/upgrade/source.ex (cache, cluster peer, release URL, SHA-256)
#   apps/server-ex/lib/hal_c2/upgrade/code.ex (a code-only version's release, on the running runtime)
#   apps/server-ex/lib/mix/tasks/hal_c2.upgrade.ex, hal_c2.bundle.ex
#   apps/server-ex/lib/hal_c2/web/router.ex (GET /api/upgrade/:token, POST /api/dev/reload)
#   mise-tasks/mc/reload
#   apps/server-ex/lib/hal_c2/web/socket.ex (serverUpdate shape, config.ready updateOutcome, @state_version)
#   apps/server-ex/rel/overlays/bin/hal-c2-service
#   packages/contracts/src/server.ts (server.updateServer, server.updateServerWithProgress, server.commitDesktopUpdate)
#   apps/server/src/cloud/selfUpdate.ts (exact versions, staged preflight, continue running threads)
#   apps/server/src/cloud/servicePreflight.ts, apps/server/src/cloud/serviceProtocol.ts
#   apps/server/src/cloud/pinnedRuntime.ts (staged install, checksum, atomic publish, one install at a time)
#   apps/server/src/serviceLauncher.ts (deferred restart marker, exact versions in service state)
#   apps/server/src/cloud/serviceLauncherClient.ts (launcher context, version match, 30 second reply)
#   docs/internals/server-updates.md
#   docs/user/updating.md
#   docs/user/background-service.md (hal-c2 update, channels)

Feature: MC self-update and release upgrades
  An MC moves to another version in place as an OTP release upgrade, and restarts into
  it under its service wrapper only when a release upgrade cannot take it: a new
  emulator or native code. Clients see progress and learn the outcome.

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
      | what                                |
      | the OTP release                     |
      | the emulator's flags                |
      | code that loads a NIF               |
      | a release from before release upgrades |

  @mc
  Scenario Outline: Changes a release upgrade carries go in place
    Given a bundle that changes <what> in place
    When a client asks the MC to update to it
    Then the MC takes the change without restarting
    And the MC reports the new version

    Examples:
      | what                |
      | a supervisor module |
      | the configuration   |

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
  Scenario: A bundle that is not the version asked for is refused
    Given the bundle cached for the target version is another version's
    When a client asks the MC to update to it
    Then the update fails saying the bundle is not that version

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

  # A process still in code from the update before would lose it to the next load.
  @mc
  Scenario: An install that fails in place falls back to a restart
    Given a process still runs code from the update before
    And a bundle that replaces that code again
    When a client asks the MC to update to it
    Then the MC restarts into the new version instead
    And it says the process holding the old code is why

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

  # Upstream #19311: its service launcher stopped the server, copied the database and gave
  # the new server 120 s to prepare. The MC upgrades in place through release upgrades, with
  # no database copy before it stops and no prepare window to miss.
  # Upstream #29464: an update killed mid-backup left a partial copy that later updates counted
  # against the free space; with no copy, the MC leaves no partial one behind.
  @dropped @mc
  Scenario: An update whose database backup cannot fit is refused before the server stops
    Given the disk has less free space than a copy of the MC's database
    When the user updates the MC
    Then the update is refused and the MC keeps running
    And a large database's first migrations do not run out the time the new version has to prepare

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
  Scenario Outline: A target that is not an exact version is refused
    When a client asks the MC to update to "<target>"
    Then the update fails saying it is not an exact version
    And the running MC is left as it was

    Examples:
      | target |
      | latest |
      | ^1.2.0 |
      | 1.2    |

  @mc @priority-high
  Scenario: A staged version that cannot run on this machine is refused before the MC stops
    Given the MC downloaded and staged the target version
    And the staged version's own preflight says it cannot run here
    When a client asks the MC to update
    Then the update fails with the preflight's reason
    And the running MC keeps serving without interruption

  @mc
  Scenario: An update can ask running turns to carry on after the restart
    Given turns are running on the MC
    When a client asks the MC to update and to continue running threads
    Then those threads are marked to continue once the new version is up
    And a restart that does not happen clears those marks

  @mc
  Scenario: An MC with no background service explains how to enable remote updates
    Given an MC that is neither the desktop app's server nor a background service
    And a bundle that needs a restart
    When a client asks the MC to update
    Then the update fails saying remote updates need the background service
    And it says to run the service install command on the server machine

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

  @mc @priority-high
  Scenario: A download cut off midway leaves no half-installed version
    Given the MC is downloading a version to install
    When the download is interrupted
    Then nothing is left that could be mistaken for an installed version
    And the running version is unchanged

  # Upstream #19649: a slow download still receiving bytes failed at a ten-minute cap.
  @mc
  Scenario: A slow download finishes while a stalled one fails
    Given the MC is downloading a version to install
    When the download is still receiving data after ten minutes
    Then it carries on until it finishes
    But a download that receives nothing for a minute fails and leaves nothing half-installed

  @mc
  Scenario: A version that is only partly installed is installed again
    Given an earlier install of a version stopped before it finished
    When the MC updates to that version
    Then it replaces the partial install with a complete one

  @mc @priority-high
  Scenario: A complete installed version survives a failed re-install
    Given a version that is fully installed
    When another install of the same version fails its checks
    Then the installed version is left in place

  # The MC runs one update at a time and refuses a second rather than queueing it ("Only one
  # update runs at a time"), so two installs never take turns; proposed for @dropped.
  @backlog @mc
  Scenario: Two installs of one version never run side by side
    Given two requests install the same version at once
    Then they take turns
    And the version ends up whole

  # Upstream #22253: every update left its old runtime on disk; nightly users had 8 to 22 GB
  # of dead versions and one server ran out of disk.
  @mc
  Scenario: Updating removes installed versions nothing can use any more
    Given the MC has installed versions "1.1.0", "1.2.0" and "1.3.0" and runs "1.3.0"
    And "1.2.0" is the version an update would roll back to
    When the MC starts after an update
    Then the installed version "1.1.0" is removed
    And "1.2.0" and "1.3.0" are kept

  # Upstream #23113: a host added over SSH starts its installed version directly rather than as a
  # service, and it kept every old runtime.
  @mc @priority-low
  Scenario: An MC started over SSH from its installed version removes old versions too
    Given an SSH host whose MC was started from its installed version "1.3.0"
    And the host still has "1.1.0" installed, which nothing uses
    When that MC starts
    Then the installed version "1.1.0" is removed

  # Upstream #22253: a version some process still runs, or one installed within the last hour
  # that nothing points at yet, is kept; when the MC cannot tell, nothing is removed.
  @mc
  Scenario Outline: An installed version that may still be in use is kept
    Given the MC has the old installed version "1.1.0"
    And <use>
    When the MC removes versions nothing can use
    Then "1.1.0" is kept

    Examples:
      | use                                                   |
      | a running process executes "1.1.0"                    |
      | "1.1.0" finished installing less than an hour ago     |
      | the MC cannot read which versions are running         |
      | the MC cannot read which version it would roll back to |

  # Upstream #22253: a removal that is cut off never leaves a partial version that looks whole.
  @mc @priority-low
  Scenario: A removal cut off midway leaves nothing that looks installed
    Given the MC is removing the old installed version "1.1.0"
    When the removal is interrupted
    Then "1.1.0" is not taken for an installed version
    And the next removal clears what was left

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

  # A reload is a release upgrade made from the checkout's build.
  @mc
  Scenario: A developer reloads changed modules into running MCs
    Given MCs started from a checkout
    When a developer reloads them after editing code
    Then only modules whose code changed are loaded
    And a changed supervisor runs its new code without restarting

  @mc
  Scenario: A reload starts the services the MC's new code adds
    Given MCs started from a checkout whose new code adds services
    When a developer reloads them after editing code
    Then the new service runs without a restart
    And a boot task that already ran does not run again
    And a new service that fails to start is reported as needing a restart
    And services it changed restart on their new specs, and ones it no longer lists stop

  @mc
  Scenario: A developer reloads the MC their checkout runs without naming it
    Given MCs started from a checkout
    When a developer reloads the local MC with its own access token
    Then only modules whose code changed are loaded
    And a changed supervisor runs its new code without restarting

  @mc
  Scenario: A developer reloads the MC from a checkout it was not started from
    Given another checkout holds edited code the MC was not started from
    When a developer reloads the local MC from that checkout
    Then only modules whose code changed are loaded
    And a changed supervisor runs its new code without restarting

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
  Scenario: A developer's bundle updates the MCs clustered with the installed one
    Given the MC is clustered with another running from a release
    And a bundle on this machine the MC has not seen
    When a developer reloads the local MC with that bundle
    Then the MC loads the changed modules in place
    And the other MC loaded that bundle's code too

  @mc
  Scenario: A version built again is installed from its newest bundle
    Given the MC already unpacked a bundle of the target version
    And that version is built again with other code
    When it updates to that version
    Then it loads the code built last

  @mc
  Scenario: A developer's release reload reaches an installed MC under a HAL-C2 home root
    Given an installed MC that keeps its files under a HAL_C2_HOME root
    When a developer reloads the installed MC naming that root
    Then the reload looks for that MC in the root's MC directories

  @mc
  Scenario Outline: A developer's release reload refuses a root that cannot name an installed MC
    When a developer reloads the installed MC naming the root "<root>"
    Then the reload is refused naming that root

    Examples:
      | root         |
      | ~/.t3        |
      | ~/.hal-c2    |
      | ~/.t3/sub    |
      | relative/dir |

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
    When an update replaces that module in place
    Then the module's old code stays for the process still in it
    And the process is not killed

  @mc
  Scenario: A process's state changes shape in an update
    Given a service whose state the new version keeps in another shape
    When an update replaces that service's module in place
    Then the service migrated its state without restarting
    And no process runs the old code

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

  # Needs a release feed per channel that an MC can poll; the MC only learns of a version a
  # client hands it today.
  @backlog @mc
  Scenario: An MC tells clients a newer version is available on its channel
    Given a newer MC release is published on the MC's channel
    When a client follows the MC's config
    Then it learns which version is available

  # Needs a `hal-c2-mc update` command that reaches the running MC and asks before
  # interrupting its turns.
  @backlog @mc
  Scenario: An operator updates the MC from its command line
    When an operator asks the MC's command line to update to the newest release
    Then the MC updates as it would for a client
    And the command asks before interrupting running turns

  @mc @priority-high
  Scenario: A failed restart returns to the previous version
    Given a restart into a new version fails before it is ready
    Then the service wrapper starts the previous version again

  # Upstream's launcher copied the database before a trial and put the copy back on a failed
  # one. HAL-C2 takes no copy (docs/internals/server-updates.md: a rollback restores the code,
  # not the data), so whether the MC should gain one is a maintainer decision.
  # Upstream #19311: its service launcher copied the database before a trial and restored
  # the copy when the trial rolled back.
  @backlog @mc
  Scenario: A failed restart returns the database to its state before the trial
    Given a restart into a new version fails before it is ready
    Then the database is restored to its state before the trial

  @mc
  Scenario: A restart the service deferred is forgotten once it runs the version it names
    Given an update asked the service to restart later
    When the service starts and runs the version it was asked for
    Then the deferred restart is cleared
    And a service that is still on an older version keeps waiting for a newer one

  # Upstream's launcher kept the active version in a state file it parsed. The MC's is
  # releases/start_erl.data, written only by HalC2.Upgrade from a target it already checked
  # is exact ("An update names one exact version"), and the start script reads it as a
  # directory name, so there is nothing to guess; proposed for @dropped.
  @backlog @mc
  Scenario: Only exact versions are accepted as the service's active version
    Given the service's state names a version that is not an exact version
    When the service starts
    Then it refuses the state rather than guessing a version

  # This scenario and the two after it test upstream's Node service launcher, which handed
  # the server startup context and an IPC channel and answered its update requests. The MC
  # runs under bin/hal-c2-service and the OS service manager, with no launcher IPC: it
  # updates itself through release_handler and restarts by exiting; proposed for @dropped.
  @backlog @mc
  Scenario Outline: An MC refuses to start under a launcher it cannot trust
    Given the service launcher started the MC and <problem>
    When the MC starts
    Then it stops saying "<message>"

    Examples:
      | problem                                  | message                                                  |
      | handed it startup context it cannot read | The service launcher supplied invalid startup context.   |
      | started a different version than the MC  | The service launcher started a different hal-c2 version. |
      | left it with no channel back             | The service launcher IPC channel is unavailable.         |

  @backlog @mc
  Scenario: A service that never answers an update request fails the update
    Given the service launcher is not answering
    When a client asks the MC to update
    Then the update fails after thirty seconds saying the launcher did not respond
    And the running MC keeps serving

  @backlog @mc
  Scenario: A service that goes away mid-request fails the update at once
    Given an update request is waiting on the service launcher
    When the service launcher disconnects
    Then the update fails saying the launcher disconnected before acknowledging

  # Desktop-app two-phase update handoff. An MC updates itself in place or restarts under
  # bin/hal-c2-service; the Electron app's bundled backend is not how HAL-C2 ships the MC.
  @dropped @mc
  Scenario: The desktop app commits a prepared update after reconnecting
    Given the desktop app prepared an update and received a token
    When it commits that token
    Then its bundled server restarts into the new version
