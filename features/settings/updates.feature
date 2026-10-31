# Sources:
#   https://github.com/pingdotgg/t3code/pull/13302 (phone maintenance of environments and providers)
#   docs/user/updating.md
#   docs/internals/server-updates.md
#   apps/server-ex/lib/hal_c2/upgrade.ex (server.updateServer, server.updateServerWithProgress)
#   apps/server-ex/lib/hal_c2/desktop_update.ex (desktop-managed updates, server.reportDesktopUpdateStatus, desktopUpdateControl)
#   apps/server-ex/lib/hal_c2/provider_updates.ex (server.updateProvider, version advisories)
#   apps/server-ex/test/mc_parity_test.exs (server.commitDesktopUpdate not applicable)
#   packages/contracts/src/rpc.ts (server.updateServer, server.updateServerWithProgress, server.commitDesktopUpdate, server.updateProvider)
#   apps/web/src/components/ServerUpdateAction.tsx
#   apps/web/src/components/desktopUpdate.logic.ts
#   apps/web/src/components/desktopUpdate.toast.tsx
#   apps/web/src/components/sidebar/SidebarUpdatePill.tsx, SidebarUpdateReleaseNotes.tsx, DesktopUpdateStatusIcon.tsx (the sidebar update button and its notes)
#   apps/web/src/components/sidebar/SidebarProviderUpdatePill.tsx (the provider update notice)
#   apps/web/src/components/ProviderUpdateLaunchNotification.logic.ts
#   apps/web/src/components/ProviderUpdatePrimaryNotification.tsx (the launch offer)
#   apps/web/src/components/ProviderUpdateEnvironmentRows.tsx (per-environment update rows, timeout, not connected)
#   apps/desktop-qt/src/native/ProviderUpdateNotice.cpp (the desktop's launch offer)
#   apps/desktop-qt/tests/native/features/ProviderSettingsSteps.cpp (runs the @desktop scenarios against a fake MC)
#   apps/desktop/src/updates/DesktopUpdates.ts
#   apps/desktop/src/updates/updateChannels.ts
#   apps/desktop/src/settings/DesktopAppSettings.ts (the update track default)
#   apps/desktop/src/window/DesktopApplicationMenu.ts (the menu's Check for Updates)
#   apps/desktop/src/updates/updateMachine.ts, DesktopRemoteUpdates.ts, remoteUpdateFlow.ts (update state transitions, updates asked for by a server)
#   apps/desktop-qt/parity/features.backlog.test.ts (app-updates)
#   apps/tui/src/features.backlog.test.ts (provider maintenance)
#   apps/tui/src/host/sections/updates.ts (the terminal client's notice and Updates page)
#   apps/server/src/desktopUpdate/DesktopAppUpdate.ts, DesktopAppUpdate.test.ts (desktop update refusals, timeouts,
#     stages, ignoring other runs)

Feature: Updating the server, the desktop app and providers
  The app and the MC can live on different machines and update separately.
  Updates are offered where the user already is, report progress, and say
  clearly whether they worked.

  Rule: Updating a server

    @mc
    Scenario: A server update reports its progress to the end
      When the user updates the server to "1.4.0" with progress
      Then the user sees it downloading, then installing
      And the update ends as complete

    @mc
    Scenario: Only one server update runs at a time
      Given a server update is in progress
      When the user starts another server update
      Then the second update is refused

    @shared
    Scenario: A server behind the app offers an update in the conversation
      Given the app is newer than the server on "server"
      When the user opens a thread on "server"
      Then the user is offered to update "server"

    @shared
    Scenario: A successful update names the version it reconnected on
      When the user updates "server" and it reconnects on "1.4.0"
      Then the user is told "server" was updated and reconnected on "1.4.0"

    # Owner of "Update all"; settings/connections.feature holds the Connections entry point
    # and version line, connections/ cross-references here.
    @shared
    Scenario: Updating every machine confirms desktop hosts first
      Given "laptop" is hosted by the desktop app and "server" is a service
      When the user updates all machines
      Then the user is asked to confirm that the desktop app on "laptop" will relaunch
      And "server" updates independently of "laptop"

    @shared
    Scenario: The user copies the update command instead
      When the user copies the update command for "server"
      Then the command for the matching version is on the clipboard

    # Legacy: apps/web/src/components/ServerUpdateAction.tsx (Update command copied, Could not copy update command)
    @desktop
    Scenario: Copying the update command says what to run and where
      When the user copies the update command for "server"
      Then the user sees a "success" toast "Update command copied" saying to run the command on "server"

    @desktop
    Scenario: A copy that fails says so
      Given the clipboard cannot be written
      When the user copies the update command for "server"
      Then the user sees an "error" toast "Could not copy update command" with the reason

    @shared
    Scenario: A dismissed update notice stays dismissed for that version
      Given the user dismissed the update notice for "1.4.0"
      When the user reconnects to the same server
      Then the notice for "1.4.0" does not return
      But a notice for "1.5.0" does appear

    @desktop
    Scenario: A failed server update says why and leaves the server where it was
      Given "server" is behind the app
      When the user updates "server" and the update fails with "Disk is full"
      Then the user is told "Server update failed" with "Disk is full"
      And "server" keeps running on its current version

    @desktop
    Scenario: A server run by another machine's desktop app asks before that app relaunches
      Given "workstation" is served by the desktop app on that machine and is behind
      When the user updates the server on "workstation"
      Then the user is asked to confirm the desktop app on "workstation" will close and relaunch
      When the user declines
      Then nothing is updated

    @desktop
    Scenario: A server run by a desktop app this client cannot update points to that machine
      Given "workstation" is served by the desktop app on that machine
      And this client cannot update that desktop app
      When the user looks at the update offer for "workstation"
      Then the user is told to update the desktop app on that machine to update the server
      And no update button is offered

    @desktop
    Scenario: Updating a server run by a desktop app says the app relaunched
      When the user updates "workstation" and its desktop app relaunches on "1.4.0"
      Then the user is told "workstation" was updated and the desktop app relaunched on "1.4.0"

  Rule: Updating the desktop app

    @desktop
    Scenario: The desktop app downloads an update and installs it on restart
      Given an update to "1.4.0" is available
      When the user downloads it
      Then the download shows its progress
      When the user restarts to install and confirms
      Then the app relaunches on "1.4.0" with the same windows

    @desktop
    Scenario: A failed download can be retried
      Given an update download failed
      When the user retries
      Then the download starts again

    @desktop
    Scenario Outline: The sidebar's update button says where the update stands
      Given <state>
      When the user points at the update button in the sidebar
      Then its tooltip says "<says>"

      Examples:
        | state                                      | says                                                    |
        | the app is up to date                      | Check for updates                                       |
        | the app is checking for an update          | Checking for updates…                                   |
        | update v1.4.0 is available                 | Update v1.4.0 ready to download                         |
        | update v1.4.0 is downloading at 42 percent | Downloading update (42%)                                |
        | update v1.4.0 was downloaded               | Update v1.4.0 downloaded. Click to restart and install. |
        | the download of v1.4.0 failed              | Download failed for v1.4.0. Click to retry.             |
        | the install of v1.4.0 failed               | Install failed for v1.4.0. Click to retry.              |

    @desktop
    Scenario: Restarting to install an update warns that running tasks stop
      Given update "v1.4.0" was downloaded
      When the user chooses to restart and install
      Then the user is asked "Install update v1.4.0 and restart HAL-C2?" and told running tasks will be interrupted
      When the user declines
      Then the app keeps running on its current version

    @desktop
    Scenario Outline: An update step that fails says so
      When <step> and it fails with "Network unreachable"
      Then the user is told "<told>" with the reason

      Examples:
        | step                                   | told                         |
        | the user checks for updates            | Could not check for updates  |
        | the user downloads the update          | Could not download update    |
        | the user restarts to install           | Could not install update     |

      # The Qt desktop asks in its own dialog, which cannot fail.
      @backlog
      Examples:
        | step                                   | told                         |
        | the user is asked to confirm a restart | Could not confirm update     |

    @desktop
    Scenario: Checking for updates in a build without updates and no reason for it says so
      Given this build has automatic updates turned off and does not say why
      When the user checks for updates
      Then the user is told "Could not check for updates" with "Automatic updates are not available in this build."

    @desktop
    Scenario: A nightly update lists what changed
      Given the user is on the Nightly track
      And a nightly update has release notes
      When the user points at the update button in the sidebar
      Then the user sees "What's changed" with the notes of the newest release
      And each older release in between is listed under "Changes in" its version

    @desktop
    Scenario Outline: Release notes link to the rest on GitHub
      Given a nightly release lists <shown> of <total> changes and <older> older releases were left out
      When the user reads the release notes
      Then the user sees a link "<link>"

      Examples:
        | shown | total | older | link                       |
        | 5     | 5     | 0     | View release on GitHub     |
        | 5     | 8     | 0     | 3 more changes on GitHub   |
        | 5     | 6     | 0     | 1 more change on GitHub    |
        | 5     | 5     | 4     | 4 older releases on GitHub |

    # Legacy: apps/desktop/src/updates/releaseNotes.ts (normalizeDesktopUpdateReleaseNotes)
    @desktop
    Scenario: Release notes are shown as plain short lines
      Given a release's notes are written with markup, links and bold text
      And one change is longer than 220 characters
      When the user reads the release notes
      Then each change is plain text with links shown as their words
      And the long change is cut short with "..."

    @desktop
    Scenario: Release notes leave out the boilerplate of a GitHub release
      Given a release's notes contain a "What's Changed" heading, compare links, "New Contributors" and "Full Changelog"
      When the user reads the release notes
      Then only the changes themselves are listed

    @desktop
    Scenario: Only releases of the followed track appear in the release notes
      Given the user is on the Nightly track
      And the notes cover a manually cut preview release as well as nightly releases
      When the user reads the release notes
      Then only the nightly releases are listed

    @desktop
    Scenario: A release with nothing to list is left out of the release notes
      Given a release's notes contain only a heading and a compare link
      When the user reads the release notes
      Then that release is not listed

    @desktop
    Scenario: A stable update shows no release notes popover
      Given the user is on the Stable track
      And an update is available
      When the user points at the update button in the sidebar
      Then the user sees only where the update stands

    @desktop
    Scenario Outline: The user switches update track
      When the user switches the update track to <track>
      Then the app checks for <track> releases
      And the user can switch back at any time

      Examples:
        | track   |
        | Nightly |
        | Stable  |

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (AboutVersionSection, track change)
    @desktop
    Scenario: A failed track change says so and keeps the current track
      Given the update track is Stable
      When the user switches the update track to Nightly and it fails with "Network unreachable"
      Then the user is told "Could not change update track" with the reason
      And the update track is still Stable

    # Legacy: apps/desktop/src/settings/DesktopAppSettings.ts (updateChannelConfiguredByUser), apps/desktop/src/updates/updateChannels.ts
    @desktop
    Scenario Outline: A track the user never chose follows the installed build
      Given the user has never chosen an update track
      And the installed build is a <build>
      When the desktop app starts
      Then the update track is <track>
      And a track the user chose earlier is kept instead

      Examples:
        | build           | track   |
        | nightly build   | Nightly |
        | stable release  | Stable  |

    # Legacy: apps/desktop/src/updates/DesktopUpdates.ts (startup delay, poll interval)
    @desktop
    Scenario: The desktop app looks for updates by itself
      Given this build can update itself
      When the app starts
      Then it checks for an update about fifteen seconds after launch
      And again every four minutes while it runs

    # Legacy: apps/desktop/src/updates/DesktopUpdates.ts (disabled reasons)
    @desktop
    Scenario Outline: A build that cannot update itself says why
      Given <situation>
      When the user checks for updates
      Then the user is told "Could not check for updates" with "<reason>"

      Examples:
        | situation                                         | reason                                                                  |
        | no update source is configured                    | Automatic updates are not available because no update feed is configured. |
        | the update source is not https                    | Automatic updates are not available because the update feed is not https. |
        | the app runs from a development or unpacked build | Automatic updates are only available in packaged production builds.      |
        | automatic updates were turned off for this run    | Automatic updates are disabled by the HAL_C2_DISABLE_AUTO_UPDATE setting. |
        | the app on Linux is not the AppImage build        | Automatic updates on Linux require running the AppImage build.            |

    # Legacy: apps/desktop/src/window/DesktopApplicationMenu.ts (check for updates from the menu)
    @desktop
    Scenario: Checking for updates from the application menu says when the app is current
      Given the app is on version "1.4.0" and no newer one exists
      When the user chooses Check for Updates from the application menu
      Then the user is told "You're up to date!" with "HAL-C2 1.4.0 is currently the newest version available."

    # Legacy: apps/desktop/src/window/DesktopApplicationMenu.ts (check for updates from the menu)
    @desktop
    Scenario Outline: Checking for updates from the application menu says when it did not work
      Given <situation>
      When the user chooses Check for Updates from the application menu
      Then the user is told "<title>" with "<detail>"

      Examples:
        | situation                                 | title               | detail                                           |
        | the check fails with "Network unreachable" | Update check failed | Network unreachable                              |
        | the check fails with no reason            | Update check failed | An unknown error occurred. Please try again later. |
        | this build cannot update itself           | Updates unavailable | the reason this build cannot update itself        |

    @desktop
    Scenario: The update track cannot change while an update step is running
      Given the app is checking for, downloading or installing an update
      When the user switches the update track
      Then the user is told the track cannot change while that update step is in progress
      And the update track stays as it was

    @desktop
    Scenario: Leaving the nightly track may install an older version
      Given the app is on the Nightly track at a build newer than the latest stable release
      When the user switches the update track to Stable
      Then the app offers the latest stable release even though it is older
      And installing it is allowed to go back in version

    @desktop
    Scenario: A failed install brings the MC back and says so
      Given the app stopped its MC to install an update
      When the install fails
      Then the MC is started again
      And the user is told "Could not install update" with the reason
      And the app keeps running on its current version

    # Legacy: apps/desktop/src/updates/updateMachine.ts (a downloaded update survives later checks)
    @desktop
    Scenario Outline: A downloaded update stays ready when a later check does not find it again
      Given update "1.4.0" was downloaded
      When a later check <outcome>
      Then the update is still shown as downloaded and ready to install

      Examples:
        | outcome                  |
        | fails                    |
        | finds nothing newer      |

    # Legacy: apps/desktop/src/updates/DesktopUpdates.ts (handleUpdateAvailable channel match)
    @desktop
    Scenario: A release from the other track is not offered
      Given the update track is Stable
      When a check finds only a nightly release
      Then the app says it is up to date

    # Legacy: apps/desktop/src/updates/DesktopUpdates.ts (checkForUpdates, shouldBroadcastDownloadProgress)
    @desktop
    Scenario: No update check starts while an update is downloading
      Given an update is downloading
      When the timer for the next automatic check comes up
      Then no check starts
      And the download goes on

    @desktop
    Scenario: Download progress is reported in steps of ten percent
      Given an update is downloading
      When the download advances from 41 to 49 percent
      Then the shown progress does not change
      When the download reaches 50 percent
      Then the shown progress becomes 50 percent

    # Legacy: apps/desktop/src/telemetry/DesktopTelemetryPublisher.ts (replays the latest update report to a backend that attaches later)
    @desktop
    Scenario: An MC that connects after an update was found hears about it
      Given the desktop app already found an update
      When its MC restarts and connects to the app
      Then the MC receives the current update state without another check

    # Legacy: apps/server/src/desktopUpdate/DesktopAppUpdate.ts (onInterrupt cancels the desktop request)
    @mc
    Scenario: Abandoning a desktop update request cancels it in the desktop app
      Given a desktop update is in progress
      When the client that asked for it goes away
      Then the MC tells the desktop app to cancel that update
      And a new desktop update can be asked for

    @desktop
    Scenario: An Intel build on an Apple Silicon Mac warns the user
      Given the Intel build runs on an Apple Silicon Mac
      When the user checks for updates
      Then the user is warned to install the Apple Silicon build

    @desktop
    Scenario Outline: The Intel build warning says what to do next
      Given the Intel build runs on an Apple Silicon Mac
      And <state>
      When the user reads the warning
      Then it says <advice>

      Examples:
        | state                              | advice                                                  |
        | an update is available to download | to download the update to switch to the native build    |
        | an update was downloaded           | to restart to install the native build                  |
        | no update is available             | the next app update will replace it with the native one |

    @desktop
    Scenario: A downloaded update links its release notes
      Given update "1.4.0" finished downloading
      Then the user is told "Update downloaded" and to restart the app from the update button
      And the notice links to the release notes of "1.4.0"

    @desktop
    Scenario: Release notes that cannot be opened say so
      Given the notice for the downloaded update links its release notes
      When the user chooses the link and the system cannot open it
      Then the user is told "Unable to open release notes"

    @mc
    Scenario: A desktop update request from a server the desktop app did not start is refused
      Given this server was not started by the desktop app
      When a client asks for a desktop update
      Then the request fails saying the server cannot drive a desktop update

    @mc
    Scenario: A desktop update request while the app is current says so
      Given the desktop app is already on the latest version
      When a client asks for a desktop update
      Then the request says the desktop app is already up to date on its version

    @mc
    Scenario: Only one desktop update runs at a time
      Given a desktop update is in progress
      When a client asks for another desktop update
      Then the request fails saying a desktop app update is already in progress

    # Legacy: apps/server/src/desktopUpdate/DesktopAppUpdate.test.ts (stages, other runs, retry after success)
    @mc
    Scenario: A desktop update reports its stages once and ignores other runs
      Given the desktop app checks, finds "1.2.4", downloads it and has it ready to install
      And it also sends a failure that belongs to an earlier request
      When a client asks for a desktop update
      Then the client is told "downloading" once, then "installing"
      And the update's target version is "1.2.4"
      And the earlier request's failure is not shown

    # Legacy: apps/server/src/desktopUpdate/DesktopAppUpdate.test.ts (failed outcome, silent desktop app)
    @mc
    Scenario Outline: A desktop update that ends badly says why
      Given the desktop app <ends>
      When a client asks for a desktop update
      Then the request fails saying "<reason>"

      Examples:
        | ends                                                       | reason                                          |
        | reports that the update failed because "feed unreachable"  | feed unreachable                                |
        | stops reporting before it has an outcome                   | The desktop app stopped reporting its update.   |

    @mc
    Scenario: A desktop update that is ready can be asked for again
      Given a desktop update was prepared and is ready to install
      When a client asks for a desktop update again
      Then the MC does not refuse it as already in progress

    @mc
    Scenario Outline: A desktop update that stalls is reported as timed out
      Given the desktop app <stage> for longer than allowed
      Then the update fails saying the desktop app <message>

      Examples:
        | stage                      | message                                  |
        | does not finish the update | did not finish the update in time        |
        | does not report an install | did not report an install result in time |

    @mc
    Scenario: An update the MC cannot keep track of is not started
      Given the MC cannot write its update state
      And a client's desktop update is ready to install
      Then the desktop app is told to cancel and not to install
      And the request fails saying "Could not save the desktop update's state: not a directory."

    @mc
    Scenario: An install whose failure cannot be saved still ends
      Given a client's desktop update is committed and the app stopped its MC to install
      And the MC stops being able to write its update state
      When the app reconnects and reports that the install failed because "disk full"
      Then the MC keeps running with no install left waiting
      And the MC's last update outcome is failed saying "disk full"
      And clients watching the MC's config are told it failed saying "disk full"

    @mc
    Scenario: An MC the desktop app started offers the update through the app
      Then the MC's descriptor says the desktop app updates it

    @mc
    Scenario: An install that fails after the MC stopped is still recorded
      Given a client's desktop update is committed and the app stopped its MC to install
      When the app reconnects and reports that the install failed because "disk full"
      Then the MC's last update outcome is failed saying "disk full"

    @mc
    Scenario: An app that relaunched leaves no failure behind
      Given a client's desktop update is committed and the app stopped its MC to install
      When the app relaunched and reconnects
      Then no install is left waiting and no failure is recorded

    @dropped @mc
    Scenario: The MC commits a desktop update after relaunch
      Given the desktop app prepared an update and relaunched
      When it commits the update with the MC
      Then the MC confirms the update
      # The MC updates itself with a hot code upgrade instead; see hot-code-upgrade.feature.

    # Legacy: apps/desktop/src/updates/remoteUpdateFlow.ts, DesktopRemoteUpdates.ts (the desktop side of an update asked for by a server).
    # Uncertain: whether the Qt desktop takes update requests from its MC at all; kept as the desktop half of the scenarios above.
    @desktop
    Scenario: A requested update looks again before saying the app is current
      Given the app last found no update some time ago
      When a server asks the desktop app to update
      Then the app checks again before answering
      And it answers that the app is up to date only after that check

    @desktop
    Scenario: A requested update gives up after three failed downloads
      Given an update is available
      When a server asks the desktop app to update and the download fails three times
      Then the request fails with the reason the download gave

    @desktop
    Scenario Outline: A requested update that cannot start says why
      Given <situation>
      When a server asks the desktop app to update
      Then the request fails with "<reason>"

      Examples:
        | situation                                         | reason                                              |
        | automatic updates are disabled on this machine    | Automatic updates are disabled on this machine.     |
        | the downloaded update is gone before it is ready  | The desktop app lost the downloaded update.         |

      # The MC gives up on a desktop app that never answers.
      @backlog
      Examples:
        | situation                                         | reason                                              |
        | the check never reports a result                  | The desktop app did not report an update result.    |

    @desktop
    Scenario: A prepared update that is not confirmed in five minutes is dropped
      Given the desktop app prepared an update for a server's request
      When five minutes pass without the request being confirmed
      Then confirming it fails with "This desktop update is no longer prepared."
      And a new update request can start

    @desktop
    Scenario: A request replaces a prepared update its MC never confirmed
      Given the desktop app prepared an update for a server's request
      Then a new update request can start

    @desktop
    Scenario: A failed install the MC could not hear reaches it once it is back
      Given a server's update is installing and its MC stopped for it
      When the install fails and the connection comes back
      Then the MC hears that request failed with the install's reason

    @desktop
    Scenario Outline: Only a download the app can verify is offered
      Given the update feed lists a release whose asset <asset>
      Then that release is <offered>

      Examples:
        | asset                                 | offered     |
        | is https with a sha256 digest         | offered     |
        | is https with no digest               | not offered |
        | is plain http with a sha256 digest    | not offered |

    @desktop
    Scenario Outline: A download is checked against its published digest
      Given a download whose bytes <match> the release's digest
      Then the app <verdict> it

      Examples:
        | match        | verdict |
        | match        | accepts |
        | do not match | refuses |

    @desktop
    Scenario: Confirming an update joins an install that is already running
      Given the desktop app is already installing the downloaded version
      When a server confirms its prepared update of that version
      Then no second install starts
      And no failure is reported

    @desktop
    Scenario: A confirmation that joined an install hears when it fails
      Given the desktop app is already installing the downloaded version
      When a server confirms its prepared update of that version
      And that install fails
      Then the MC hears that request failed with the install's reason
      And a new update request can start

  Rule: Updating providers

    @mc
    Scenario Outline: A provider behind the latest release offers an update
      Given <provider> is installed with <installer> and a newer version is released
      When the MC checks provider versions
      Then <provider> is reported behind the latest version with an update command

      Examples:
        | provider | installer         |
        | Codex    | Homebrew          |
        | Codex    | a global npm install |
        | Claude   | its own updater   |

    @mc
    Scenario: Updating a provider installs the latest release
      Given Codex is behind the latest version
      When the user updates Codex
      Then the MC runs Codex's update command
      And Codex is reported current

    @mc
    Scenario Outline: A provider update that cannot run
      Given Codex <state>
      When the user updates Codex
      Then the user is told "<message>"

      Examples:
        | state                                  | message                                         |
        | is not installed                       | Codex is not installed on this machine.         |
        | was installed in a way the MC cannot update | This installation cannot be updated from here. |

    @mc
    Scenario: The user turns off provider update checks
      Given the user turned off provider update checks
      When the MC would check provider versions
      Then no version check is made

    @desktop
    Scenario: At launch an outdated provider is offered its update
      Given "Codex" is behind its latest release
      When the desktop shell is connected to its MC
      Then the user sees a "warning" toast "Update Available: Codex v0.51.0" saying "Install the update now or review provider settings."
      And the toast "Update Available: Codex v0.51.0" offers "Update" and "Settings"

    @desktop
    Scenario: At launch the offered update runs and reports it finished
      Given "Codex" is behind its latest release
      And the desktop shell is connected to its MC
      When the user chooses "Update" on the toast "Update Available: Codex v0.51.0"
      And the update finishes
      And the MC reports "Codex" updated
      Then the user sees a "success" toast "Provider updated" saying "New sessions will use the updated provider."

    @desktop
    Scenario: At launch an offered update that is refused says why
      Given "Codex" is behind its latest release
      And updating "Codex" fails with "npm is not installed"
      And the desktop shell is connected to its MC
      When the user chooses "Update" on the toast "Update Available: Codex v0.51.0"
      Then the user sees an "error" toast "Provider update failed" saying "npm is not installed"

    @desktop
    Scenario: At launch the update offer leads to the provider settings
      Given "Codex" is behind its latest release
      And the desktop shell is connected to its MC
      When the user chooses "Settings" on the toast "Update Available: Codex v0.51.0"
      Then the Providers settings open

    @desktop
    Scenario: At launch a closed update offer stays closed for that version
      Given "Codex" is behind its latest release
      And the desktop shell is connected to its MC
      When the user dismisses the toast "Update Available: Codex v0.51.0"
      And the user restarts the app
      Then the user sees no toast

    @shared
    Scenario: Provider updates on several machines report each machine
      Given Codex is behind on "laptop" and on its WSL environment
      When the user updates Codex on both
      Then each machine shows whether its update succeeded, was unchanged or failed

    @desktop
    Scenario Outline: The sidebar shows how a provider update is going
      Given <state>
      When the user looks at the bottom of the sidebar
      Then the sidebar notice says "<notice>"

      Examples:
        | state                                      | notice                      |
        | Codex is being updated                     | Updating Codex              |
        | Codex and Claude are being updated         | Updating 2 providers        |
        | Codex was updated to 0.52.0                | Codex updated: v0.52.0      |
        | Codex and Claude were updated              | 2 providers updated         |
        | the update of Codex to 0.52.0 failed       | Codex v0.52.0 update failed |
        | the updates of two providers failed        | 2 provider updates failed   |
        | Codex was updated but is still out of date | Codex still needs an update |

    @desktop
    Scenario: A finished provider update notice goes away by itself
      Given the sidebar says "Codex updated: v0.52.0"
      When three seconds pass
      Then the sidebar notice is gone

    @desktop
    Scenario: A failed provider update notice stays until it is dismissed
      Given the sidebar says "Codex update failed"
      When the user dismisses the notice
      Then the notice is gone
      And it does not return until the provider's update status changes

    @desktop
    Scenario: The provider update notice opens the provider settings
      Given the sidebar says "Codex update failed"
      When the user chooses the notice
      Then the Providers settings open

    @desktop
    Scenario: Provider updates that finished before the app connected are not announced
      Given Codex finished updating before the app connected
      When the user looks at the bottom of the sidebar
      Then the sidebar shows no provider update notice

    @desktop
    Scenario: Several outdated providers are offered together at launch
      Given "Codex" and "Claude" are behind their latest releases
      When the desktop shell is connected to its MC
      Then the user sees a "warning" toast "Updates Available: 2 providers"
      When the user chooses "Update" on the toast "Updates Available: 2 providers"
      Then the user sees a "loading" toast "Updating providers" saying "Running provider update command."

    @desktop
    Scenario: A provider that cannot be updated from here is offered only its settings
      Given "Codex" is behind its latest release
      And no update command runs for "Codex" from here
      When the desktop shell is connected to its MC
      Then the user sees a "warning" toast saying "Codex can be updated from provider settings."
      And the toast offers "Settings" and not "Update"

    @desktop
    Scenario Outline: A provider whose latest release is not usable is not offered
      Given "Codex" is behind its latest release
      And that release is <flag>
      When the desktop shell is connected to its MC
      Then the user sees no toast

      Examples:
        | flag                                |
        | known to be broken with this app    |
        | not supported by this app           |

    @desktop
    Scenario: A disabled provider is not offered an update
      Given "Codex" is behind its latest release
      And "Codex" is turned off
      When the desktop shell is connected to its MC
      Then the user sees no toast

    @desktop
    Scenario: A newer release of a dismissed provider is offered again
      Given the user dismissed the toast "Update Available: Codex v0.51.0"
      When "Codex" v0.52.0 is released and the MC checks provider versions
      Then the user sees a "warning" toast "Update Available: Codex v0.52.0"

    @desktop
    Scenario: A provider that is still out of date after its update says so
      Given "Codex" is behind its latest release
      And the desktop shell is connected to its MC
      When the user chooses "Update" on the toast "Update Available: Codex v0.51.0"
      And the MC reports "Codex" still outdated after the update
      Then the user sees a "warning" toast "Provider still needs an update" saying "Codex still appears outdated. Check provider settings for details."

    @desktop
    Scenario: A failed update with no reason names the provider
      Given "Codex" is behind its latest release
      And the desktop shell is connected to its MC
      When the user chooses "Update" on the toast "Update Available: Codex v0.51.0"
      And the update fails without saying why
      Then the user sees an "error" toast "Provider update failed" saying "Codex failed to update. Check provider settings for details."

    @desktop
    Scenario: A provider with several instances gets one offer
      Given "Codex" is behind its latest release through two of its instances
      When the desktop shell is connected to its MC
      Then the user sees one toast "Update Available: Codex v0.51.0"

    @desktop
    Scenario: A provider installed more than one way is not updated in one click
      Given "Codex" has two instances that would be updated by different commands
      When the desktop shell is connected to its MC
      Then the user sees a toast that offers "Settings" and not "Update"

    @desktop
    Scenario: Windows and WSL are offered their updates separately
      Given the app runs on Windows with a WSL backend
      And "Codex" is behind on Windows and on WSL "Ubuntu"
      When both environments connect
      Then the user sees one update notice listing "Windows" and "WSL · Ubuntu"
      And each environment has its own Update button

    @desktop
    Scenario: The update notice waits for a WSL backend that is still starting
      Given the app runs on Windows with a WSL backend that is still connecting
      And "Codex" is behind on Windows
      When the desktop shell is connected to its MC
      Then no update notice is shown yet
      When the WSL backend connects
      Then the update notice is shown once for both environments

    @desktop
    Scenario Outline: Each environment's update row shows how its update went
      Given the update notice lists "Windows" and "WSL · Ubuntu"
      When the update of "WSL · Ubuntu" <happens>
      Then the row of "WSL · Ubuntu" says "<says>"
      And the row of "Windows" is unaffected

      Examples:
        | happens                                   | says                                  |
        | is running                                | Updating…                             |
        | finishes                                  | Updated                               |
        | fails with "npm is not installed"         | npm is not installed                  |
        | leaves the provider still outdated        | Codex still appears outdated. Review provider settings for details. |

    @desktop
    Scenario: A changed set of environment updates is offered again
      Given the user dismissed the update notice for "Codex" on Windows
      When "Claude" also falls behind on "WSL · Ubuntu"
      Then the update notice is shown again listing both

    # Legacy: apps/web/src/components/ProviderUpdateEnvironmentRows.tsx (PENDING_EXPIRY_MS, "Update timed out")
    @desktop
    Scenario: A provider update that never answers is given up on after six minutes
      Given the update notice lists "Windows" and "WSL · Ubuntu"
      And the update of "WSL · Ubuntu" has been running for six minutes without an answer
      Then the row of "WSL · Ubuntu" says "Update timed out — try again."
      And the update can be started again from that row
      And the row of "Windows" is unaffected

    @desktop
    Scenario: A late answer replaces a timed out update
      Given the update of "WSL · Ubuntu" timed out
      When the update of "WSL · Ubuntu" finally finishes
      Then the row of "WSL · Ubuntu" says "Updated"

    @desktop
    Scenario: A provider update on an environment that is not connected says so
      Given the update notice lists "Windows" and "WSL · Ubuntu"
      And "WSL · Ubuntu" is not connected
      When the user starts the update of "WSL · Ubuntu"
      Then the row of "WSL · Ubuntu" says "This environment isn’t connected — try again once it reconnects."

  Rule: Maintaining an environment from a phone

    @mobile
    Scenario: A desktop app's install that fails is shown and can be tried again
      Given the user updated the desktop app on "server" and is waiting for it to come back
      When its MC says the install failed because "disk full"
      Then the user is told "server update failed: disk full"
      And the update of "server" can be started again

    @mobile
    Scenario: An update that never comes back on a new version stops waiting
      Given the user updated "server" and it comes back on the same version
      When the wait for it runs out
      Then the user is told "server update failed: it did not come back on a new version. Try again."
      And the update of "server" can be started again

    @mobile
    Scenario: A machine that comes back after the wait ran out counts as updated
      Given the user updated "server" and it comes back on the same version
      When the wait for it runs out
      And "server" comes back on "1.4.0"
      Then the user is told "server" was updated and reconnected on "1.4.0"

    @mobile
    Scenario: The phone checks an environment's release on the channel the host follows
      Given "server" is connected to the phone
      When the user checks "server" for updates
      Then the phone says whether a newer HAL-C2 release is available on "server"'s channel

    @mobile
    Scenario: The phone lists only the enabled providers of an environment for update
      Given Codex is enabled on "server" and Claude is not
      When the user opens the maintenance of "server" on the phone
      Then only Codex is offered for update on "server"

    @mobile
    Scenario: The phone shows a provider update until it ends
      Given Codex is enabled on "server" and behind its latest release
      When the user updates Codex on "server" from the phone
      Then the phone shows the update's progress until it ends
      And it says whether the update succeeded and, if it failed, why

    @mobile
    Scenario Outline: Maintenance of an environment needs a live connection and the operate scope
      Given "server" <state>
      When the user opens the maintenance of "server" on the phone
      Then its updates cannot be started and the user is told why

      Examples:
        | state                                       |
        | is not connected                            |
        | is connected without the operate scope      |

    # HAL-C2 Connect was removed (connections/agent-activity-publishing.feature), so environments
    # reached through it are not maintained from a phone; direct connections are.
    @dropped @mobile
    Scenario: Environment updates over HAL-C2 Connect
      Given "server" is reached through HAL-C2 Connect
      When the user opens the maintenance of "server" on the phone
      Then its updates are not offered
