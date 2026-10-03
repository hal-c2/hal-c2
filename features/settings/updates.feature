# Sources:
#   docs/user/updating.md
#   docs/internals/server-updates.md
#   apps/server-ex/lib/hal_c2/upgrade.ex (server.updateServer, server.updateServerWithProgress)
#   apps/server-ex/lib/hal_c2/provider_updates.ex (server.updateProvider, version advisories)
#   apps/server-ex/test/mc_parity_test.exs (server.commitDesktopUpdate not applicable)
#   packages/contracts/src/rpc.ts (server.updateServer, server.updateServerWithProgress, server.commitDesktopUpdate, server.updateProvider)
#   apps/web/src/components/ServerUpdateAction.tsx
#   apps/web/src/components/desktopUpdate.logic.ts
#   apps/web/src/components/desktopUpdate.toast.tsx
#   apps/web/src/components/ProviderUpdateLaunchNotification.logic.ts
#   apps/web/src/components/ProviderUpdatePrimaryNotification.tsx (the launch offer)
#   apps/desktop-qt/src/native/ProviderUpdateNotice.cpp (the desktop's launch offer)
#   apps/desktop-qt/tests/native/features/ProviderSettingsSteps.cpp (runs the @desktop scenarios against a fake MC)
#   apps/desktop/src/updates/DesktopUpdates.ts
#   apps/desktop/src/updates/updateChannels.ts
#   apps/desktop-qt/parity/features.backlog.test.ts (app-updates)
#   apps/tui/src/features.backlog.test.ts (provider maintenance)
#   apps/tui/src/host/sections/updates.ts (the terminal client's notice and Updates page)

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

    @shared @backlog-desktop @backlog-mobile
    Scenario: A server behind the app offers an update in the conversation
      Given the app is newer than the server on "server"
      When the user opens a thread on "server"
      Then the user is offered to update "server"

    @shared @backlog-desktop @backlog-mobile
    Scenario: A successful update names the version it reconnected on
      When the user updates "server" and it reconnects on "1.4.0"
      Then the user is told "server" was updated and reconnected on "1.4.0"

    # Owner of "Update all"; settings/connections.feature holds the Connections entry point
    # and version line, connections/ cross-references here.
    @shared @backlog-desktop @backlog-mobile
    Scenario: Updating every machine confirms desktop hosts first
      Given "laptop" is hosted by the desktop app and "server" is a service
      When the user updates all machines
      Then the user is asked to confirm that the desktop app on "laptop" will relaunch
      And "server" updates independently of "laptop"

    @shared @backlog-desktop @backlog-mobile
    Scenario: The user copies the update command instead
      When the user copies the update command for "server"
      Then the command for the matching version is on the clipboard

    @shared @backlog-desktop @backlog-mobile
    Scenario: A dismissed update notice stays dismissed for that version
      Given the user dismissed the update notice for "1.4.0"
      When the user reconnects to the same server
      Then the notice for "1.4.0" does not return
      But a notice for "1.5.0" does appear

  Rule: Updating the desktop app

    @backlog @desktop
    Scenario: The desktop app downloads an update and installs it on restart
      Given an update to "1.4.0" is available
      When the user downloads it
      Then the download shows its progress
      When the user restarts to install and confirms
      Then the app relaunches on "1.4.0" with the same windows

    @backlog @desktop
    Scenario: A failed download can be retried
      Given an update download failed
      When the user retries
      Then the download starts again

    @backlog @desktop
    Scenario Outline: The user switches update track
      When the user switches the update track to <track>
      Then the app checks for <track> releases
      And the user can switch back at any time

      Examples:
        | track   |
        | Nightly |
        | Stable  |

    @backlog @desktop
    Scenario: An Intel build on an Apple Silicon Mac warns the user
      Given the Intel build runs on an Apple Silicon Mac
      When the user checks for updates
      Then the user is warned to install the Apple Silicon build

    @dropped @mc
    Scenario: The MC commits a desktop update after relaunch
      Given the desktop app prepared an update and relaunched
      When it commits the update with the MC
      Then the MC confirms the update
      # The MC updates itself with a hot code upgrade instead; see hot-code-upgrade.feature.

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

    @shared @backlog-desktop @backlog-mobile
    Scenario: Provider updates on several machines report each machine
      Given Codex is behind on "laptop" and on its WSL environment
      When the user updates Codex on both
      Then each machine shows whether its update succeeded, was unchanged or failed
