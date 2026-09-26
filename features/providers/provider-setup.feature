# Sources:
#   docs/internals/providers.md (setup never as a health-check side effect, update ownership proven by real path)
#   apps/server-ex/lib/t3/provider_auth.ex (provider.auth.start, provider.auth.respond, provider.auth.complete, provider.auth.cancel, provider.auth.logout, provider.auth.subscribe)
#   apps/server-ex/lib/t3/provider_updates.ex (server.updateProvider, versionAdvisory)
#   apps/server/src/provider/providerMaintenance.ts, apps/server/src/provider/providerMaintenanceRunner.ts
#   apps/server/src/provider/providerCompatibility.ts (applyProviderCompatibility, latestVersionStatus)
#   apps/web/src/components/settings/providerStatus.ts (getProviderVersionAdvisoryPresentation)
#   apps/web/src/components/settings/ProviderAuthenticationSection.tsx, apps/web/src/components/settings/ProviderAuthTerminal.tsx
#   apps/web/src/components/settings/ProviderSetupSection.tsx
#   apps/mobile/src/features/settings/SettingsProviderAccountsRouteScreen.tsx
#   packages/contracts/src/providerSetup.ts (ProviderAuthState, ProviderInstallState, ProviderSetupError)
#   packages/contracts/src/rpc.ts (provider.install.start, provider.install.cancel, provider.install.remove, provider.install.subscribe, server.updateProvider)

@node
Feature: Provider setup, updates and sign-in
  Every provider plugin goes through the same setup: find or install its runtime, keep
  it current through whatever installed it, and sign in when the provider supports
  signing in from T3 Code. Checking a provider never installs or signs in anything.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Checking provider status never installs or signs in anything
    Given Grok is enabled but not signed in
    When the node checks its providers in the background
    Then no sign-in or installation is started

  Scenario: An update is run by the installer that owns the provider
    Given Codex was installed with Homebrew and is outdated
    When the user updates Codex
    Then Codex is updated through Homebrew

  # Neither server invents a command for an installation it cannot prove it owns
  # (provider_updates.ex update_command/2, providerMaintenance.ts manual-only);
  # settings/updates.feature covers the refusal when the user updates anyway.
  Scenario: A provider no installer owns is not offered an update
    Given Claude was installed in a way the node cannot identify
    When the user opens Claude's update details
    Then no update command is offered for Claude

  Scenario: Only providers that support it sign in from T3 Code
    When the user tries to sign in to Codex from T3 Code
    Then the user is told this provider does not sign in here

  Scenario: A sign-in is shared by every client of the node
    Given two clients are connected to the node
    When the user starts signing in to an ACP agent on one client
    Then the other client shows the same sign-in in progress
    And either client can finish or cancel it

  Scenario: Only one sign-in runs per provider instance
    Given a sign-in is in progress for an ACP agent
    When the user starts another sign-in for the same instance
    Then the running sign-in is kept

  Scenario: A pasted return address is refused by providers that do not use one
    Given a sign-in is in progress for an ACP agent
    When the user pastes a return address
    Then the user is told this provider does not accept a pasted redirect URL

  Scenario: Sign-in errors never show sign-in codes or addresses
    When a sign-in fails
    Then the error shown to the user contains no sign-in code or return address

  @backlog
  Scenario: A provider update waits for another update to finish
    Given a Claude update is running
    When the user updates Codex
    Then Codex's update waits for the Claude update to finish

  @backlog
  Scenario: An update that leaves the provider outdated is reported as unchanged
    When an update finishes but the provider still reports the old version
    Then the user is told the provider is still outdated

  @backlog
  Scenario: An update fails if the provider moved since it was checked
    Given Codex was reinstalled somewhere else after the last check
    When the user updates Codex
    Then the update fails asking the user to refresh and try again

  @backlog
  Scenario Outline: A provider version outside the supported range is flagged
    Given the installed provider version is <status> for this T3 Code release
    When the user opens the provider list
    Then the provider shows "<title>"

    Examples:
      | status              | title                 |
      | of limited support  | Limited support       |
      | unsupported         | Unsupported version   |
      | known to be broken  | Known broken version  |

  @backlog
  Scenario: No update is offered when the latest release is itself incompatible
    Given Codex is behind the latest release
    And that latest release is known to be broken with this T3 Code release
    When the user opens the provider list
    Then Codex is not offered an update to that release

  # The managed-install RPCs (provider.install.start, provider.install.subscribe,
  # provider.install.cancel, provider.install.remove) are not routed by apps/server-ex.
  @backlog
  Scenario: A managed runtime reports install progress to every client
    Given two clients are connected to the node
    When the user installs a managed provider runtime on one client
    Then both clients show the download progress

  @backlog
  Scenario: A managed installation can be cancelled
    Given a managed provider runtime is downloading
    When the user cancels the installation
    Then the download stops and the previous runtime is unchanged

  @backlog
  Scenario: A managed runtime can be removed and installed again
    Given a managed provider runtime is installed and not in use
    When the user removes it
    Then the provider shows that it is not installed
    When the user installs it again
    Then the provider is installed

  @backlog @mobile
  Scenario: The mobile app lists providers that can sign in from T3 Code
    When the user opens provider accounts on the mobile app
    Then only providers with in-app sign-in are listed, per device

  @backlog @mobile
  Scenario: Answering a terminal sign-in from the mobile app
    Given a terminal sign-in for an ACP agent is waiting for input
    When the user sends a response from the mobile app
    Then the response reaches the sign-in terminal on the node

  @backlog @desktop @mobile
  Scenario: Signing out asks for confirmation and keeps history
    Given the user is signed in to an ACP agent
    When the user signs out and confirms
    Then running threads sharing that sign-in stop
    And thread history is kept

  @backlog @desktop @mobile
  Scenario: The signed-in email is hidden until the user reveals it
    Given a provider is signed in as "me@example.com"
    When the user opens the provider
    Then the account is shown as signed in with the email hidden
    When the user reveals the email
    Then "me@example.com" is shown
