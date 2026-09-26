# Sources:
#   docs/user/updating.md
#   docs/internals/server-updates.md
#   apps/server-ex/lib/t3/upgrade.ex (server.updateServer, server.updateServerWithProgress)
#   apps/server-ex/lib/t3/provider_updates.ex (server.updateProvider, version advisories)
#   apps/server-ex/test/node_parity_test.exs (server.commitDesktopUpdate not applicable)
#   packages/contracts/src/rpc.ts (server.updateServer, server.updateServerWithProgress, server.commitDesktopUpdate, server.updateProvider)
#   apps/web/src/components/ServerUpdateAction.tsx
#   apps/web/src/components/desktopUpdate.logic.ts
#   apps/web/src/components/desktopUpdate.toast.tsx
#   apps/web/src/components/ProviderUpdateLaunchNotification.logic.ts
#   apps/desktop/src/updates/DesktopUpdates.ts
#   apps/desktop/src/updates/updateChannels.ts
#   apps/desktop-qt/parity/features.backlog.test.ts (app-updates)
#   apps/tui/src/features.backlog.test.ts (provider maintenance)

Feature: Updating the server, the desktop app and providers
  The app and the node can live on different machines and update separately.
  Updates are offered where the user already is, report progress, and say
  clearly whether they worked.

  Rule: Updating a server

    @node
    Scenario: A server update reports its progress to the end
      When the user updates the server to "1.4.0" with progress
      Then the user sees it downloading, then installing
      And the update ends as complete

    @node
    Scenario: Only one server update runs at a time
      Given a server update is in progress
      When the user starts another server update
      Then the second update is refused

    @backlog @shared
    Scenario: A server behind the app offers an update in the conversation
      Given the app is newer than the server on "server"
      When the user opens a thread on "server"
      Then the user is offered to update "server"

    @backlog @shared
    Scenario: A successful update names the version it reconnected on
      When the user updates "server" and it reconnects on "1.4.0"
      Then the user is told "server" was updated and reconnected on "1.4.0"

    # Owner of "Update all"; settings/connections.feature holds the Connections entry point
    # and version line, connections/ cross-references here.
    @backlog @shared
    Scenario: Updating every machine confirms desktop hosts first
      Given "laptop" is hosted by the desktop app and "server" is a service
      When the user updates all machines
      Then the user is asked to confirm that the desktop app on "laptop" will relaunch
      And "server" updates independently of "laptop"

    @backlog @shared
    Scenario: The user copies the update command instead
      When the user copies the update command for "server"
      Then the command for the matching version is on the clipboard

    @backlog @shared
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

    @dropped @node
    Scenario: The node commits a desktop update after relaunch
      Given the desktop app prepared an update and relaunched
      When it commits the update with the node
      Then the node confirms the update
      # The node updates itself with a hot code upgrade instead; see hot-code-upgrade.feature.

  Rule: Updating providers

    @node
    Scenario Outline: A provider behind the latest release offers an update
      Given <provider> is installed with <installer> and a newer version is released
      When the node checks provider versions
      Then <provider> is reported behind the latest version with an update command

      Examples:
        | provider | installer         |
        | Codex    | Homebrew          |
        | Codex    | a global npm install |
        | Claude   | its own updater   |

    @node
    Scenario: Updating a provider installs the latest release
      Given Codex is behind the latest version
      When the user updates Codex
      Then the node runs Codex's update command
      And Codex is reported current

    @node
    Scenario Outline: A provider update that cannot run
      Given Codex <state>
      When the user updates Codex
      Then the user is told "<message>"

      Examples:
        | state                                  | message                                         |
        | is not installed                       | Codex is not installed on this machine.         |
        | was installed in a way the node cannot update | This installation cannot be updated from here. |

    @backlog @node
    Scenario: The user turns off provider update checks
      Given the user turned off provider update checks
      When the node would check provider versions
      Then no version check is made

    @backlog @shared
    Scenario: Provider updates on several machines report each machine
      Given Codex is behind on "laptop" and on its WSL environment
      When the user updates Codex on both
      Then each machine shows whether its update succeeded, was unchanged or failed
