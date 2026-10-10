# Sources:
#   docs/internals/providers.md (setup never as a health-check side effect, update ownership proven by real path)
#   apps/server-ex/lib/hal_c2/provider_auth.ex (provider.auth.start, provider.auth.respond, provider.auth.complete, provider.auth.cancel, provider.auth.logout, provider.auth.subscribe)
#   apps/server-ex/lib/hal_c2/provider_updates.ex (server.updateProvider, versionAdvisory)
#   apps/server/src/provider/providerMaintenance.ts, apps/server/src/provider/providerMaintenanceRunner.ts
#   apps/server/src/provider/providerMaintenanceCommandCoordinator.ts, apps/server/src/provider/providerInstallation.ts
#   apps/server/src/provider/ProviderAuthFlow.ts, apps/server/src/provider/Layers/ProviderAuthService.ts
#   apps/server/src/provider/providerCompatibility.ts (applyProviderCompatibility, latestVersionStatus)
#   apps/server-ex/lib/hal_c2/provider_compatibility.ex (compatibilityAdvisory)
#   apps/web/src/components/settings/providerStatus.ts (getProviderVersionAdvisoryPresentation)
#   apps/web/src/components/settings/ProviderAuthenticationSection.tsx, apps/web/src/components/settings/ProviderAuthTerminal.tsx
#   apps/web/src/components/settings/ProviderSetupSection.tsx
#   apps/mobile/src/features/settings/SettingsProviderAccountsRouteScreen.tsx
#   packages/contracts/src/providerSetup.ts (ProviderAuthState, ProviderInstallState, ProviderSetupError)
#   apps/desktop-qt/src/native/ProviderSettingsController.cpp (the desktop's sign-out and email)
#   packages/contracts/src/rpc.ts (provider.install.start, provider.install.cancel, provider.install.remove, provider.install.subscribe, server.updateProvider)

@mc
Feature: Provider setup, updates and sign-in
  Every provider plugin goes through the same setup: find or install its runtime, keep
  it current through whatever installed it, and sign in when the provider supports
  signing in from HAL-C2. Checking a provider never installs or signs in anything.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Checking provider status never installs or signs in anything
    Given Grok is enabled but not signed in
    When the MC checks its providers in the background
    Then no sign-in or installation is started

  Scenario: An update is run by the installer that owns the provider
    Given Codex was installed with Homebrew and is outdated
    When the user updates Codex
    Then Codex is updated through Homebrew

  Scenario: Only npm installs can install a chosen version
    Given Codex was installed with Homebrew and is outdated
    When the user installs Codex "0.1.5"
    Then the user is told this installation cannot install "v0.1.5"

  # Neither server invents a command for an installation it cannot prove it owns
  # (provider_updates.ex update_command/2, providerMaintenance.ts manual-only);
  # settings/updates.feature covers the refusal when the user updates anyway.
  Scenario: A provider no installer owns is not offered an update
    Given Claude was installed in a way the MC cannot identify
    When the user opens Claude's update details
    Then no update command is offered for Claude

  # Ownership is proven from where the executable really lives, never from a name
  # (apps/server/src/provider/providerMaintenance.ts resolvePackageManagedProviderMaintenance).
  @backlog @mc
  Scenario Outline: A package manager that proves it owns the executable updates it
    Given Codex's executable lives in <location>
    When the user opens Codex's update details
    Then the update command runs <updater> to install the latest Codex

    Examples:
      | location                         | updater                                   |
      | a Vite+ global install           | Vite+ against that global install         |
      | a Bun global install             | Bun against that global install           |
      | a pnpm global install            | pnpm against that global install          |
      | an npm global prefix             | npm against that same prefix              |

  @backlog @mc
  Scenario: A package inside a project folder is not a global install
    Given Codex's executable is a package inside a project's node_modules
    When the user opens Codex's update details
    Then no update command is offered for Codex

  @backlog @mc
  Scenario: A Node installed by Homebrew still updates its global packages through npm
    Given Codex was installed with npm into a Node that Homebrew installed
    When the user opens Codex's update details
    Then the update command runs npm and not Homebrew

  @backlog @mc
  Scenario: A Homebrew keg outside the Homebrew that would run the upgrade is not updated by it
    Given Codex's executable sits in a Homebrew keg under a different prefix than the brew on the path
    When the user opens Codex's update details
    Then no update command is offered for Codex

  @backlog @mc
  Scenario: A version manager's shim is never updated through Homebrew
    Given Codex's executable is a shim that resolves into Homebrew's mise
    When the user opens Codex's update details
    Then no update command is offered for Codex

  @backlog @mc
  Scenario: A provider's own updater targets the home that instance uses
    Given Codex was installed by its own installer
    And this Codex instance uses its own provider home
    When the user updates Codex
    Then Codex's updater runs against that home and not the default one

  @backlog @mc
  Scenario: The update command is copyable as written
    Given Codex's executable path contains spaces
    When the user opens Codex's update details
    Then the update command quotes that path so it can be pasted into a shell

  @backlog @mc
  Scenario: The installer's own answer decides whether a newer Homebrew version exists
    Given Codex was installed with Homebrew
    And npm already has a release that Homebrew has not published yet
    When the MC checks provider versions
    Then Codex is compared against the version Homebrew would install

  @backlog @mc
  Scenario: A Homebrew install whose latest version cannot be read shows no update
    Given Codex was installed with Homebrew
    And Homebrew does not answer within ten seconds
    When the MC checks provider versions
    Then Codex's update status is unknown

  @backlog @mc
  Scenario: Latest versions are looked up at most once an hour per package
    Given Codex was installed with npm
    When the MC checks provider versions twice within an hour
    Then the registry is asked for the latest Codex version once

  @backlog @mc
  Scenario: A registry that does not answer leaves the update status unknown
    Given Codex was installed with npm
    And the package registry does not answer within four seconds
    When the MC checks provider versions
    Then Codex's update status is unknown
    And no error is shown to the user

  @backlog @mc
  Scenario Outline: A provider that cannot be updated yet is not checked against the registry
    Given Codex is <state>
    When the MC checks provider versions
    Then no latest version is looked up for Codex

    Examples:
      | state                            |
      | disabled                         |
      | not installed                    |
      | installed but reports no version |

  Scenario: Only providers that support it sign in from HAL-C2
    When the user tries to sign in to Codex from HAL-C2
    Then the user is told this provider does not sign in here

  Scenario: A sign-in is shared by every client of the MC
    Given two clients are connected to the MC
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

  # ProviderAuthFlow.ts keeps a running sign-in private to the client that started it. This
  # differs from "A sign-in is shared by every client of the MC" above; see the audit report.
  @backlog @mc
  Scenario: Another client sees that a sign-in is running but not its address or code
    Given the user started a sign-in for an ACP agent on one client
    When another client looks at that provider
    Then it shows "Sign-in is in progress in another client."
    And it shows no sign-in address or interaction

  @backlog @mc
  Scenario: Only the client that started a sign-in can answer or cancel it
    Given the user started a sign-in for an ACP agent on one client
    When another client answers or cancels that sign-in
    Then the user is told "This sign-in is no longer active in this client."
    And the sign-in keeps running

  @backlog @mc
  Scenario: A sign-in that expired cannot be answered
    Given a sign-in for an ACP agent expired after five minutes
    When the user answers it
    Then the user is told "This sign-in is no longer active in this client."

  @backlog @mc
  Scenario: A sign-in method the provider does not offer is refused
    When the user starts a sign-in with a method the provider did not advertise
    Then the user is told "The provider did not advertise this sign-in method."

  @backlog @mc
  Scenario Outline: A sign-in tells the user where it is
    Given the user started a sign-in for an ACP agent
    When <event>
    Then the sign-in shows "<message>"

    Examples:
      | event                                          | message                         |
      | the provider has been asked to start           | Starting sign-in.               |
      | the provider waits for the user to finish      | Complete sign-in to continue.   |
      | the provider is checking the finished sign-in  | Checking provider sign-in.      |
      | the user cancels the sign-in                   | Sign-in cancelled.              |
      | the sign-in fails for no known reason          | Sign-in failed. Start again.    |
      | five minutes pass without an answer            | Sign-in expired. Start again.   |

  @backlog @mc
  Scenario: Signing out says whether it worked
    Given the user is signed in to an ACP agent
    When the user signs out and it succeeds
    Then the provider shows "Signed out."
    When the user signs out and it fails
    Then the provider shows "Could not sign out. Try again."

  @backlog @mc
  Scenario: Sign-in methods already known stay listed when a refresh fails
    Given an ACP agent's sign-in methods were listed
    When the MC cannot refresh them
    Then the earlier methods stay listed
    And the user is told why they could not be refreshed

  @backlog @mc
  Scenario: A sign-in cannot start while the provider is signing out
    Given the provider is signing out
    When the user starts a sign-in
    Then the user is told "Provider setup is already in progress."

  @backlog @mc
  Scenario: A second client cannot start a sign-in while another client's runs
    Given the user started a sign-in for an ACP agent on one client
    When another client starts a sign-in for the same instance
    Then the user is told "Provider setup is already in progress."
    And the first sign-in keeps running

  @backlog @mc
  Scenario: Instances that share a login are told when it changed
    Given two instances of a provider share one login
    When the login of one of them changes
    Then the other instance shows "This provider's shared sign-in changed."
    And its running sessions stop

  Scenario: A provider update waits for another update to finish
    Given a Claude update is running
    When the user updates Codex
    Then Codex's update waits for the Claude update to finish

  Scenario: An update that leaves the provider outdated is reported as unchanged
    When an update finishes but the provider still reports the old version
    Then the user is told the provider is still outdated

  Scenario: An update fails if the provider moved since it was checked
    Given Codex was reinstalled somewhere else after the last check
    When the user updates Codex
    Then the update fails asking the user to refresh and try again

  @backlog @mc
  Scenario: An update that runs too long is stopped
    Given Codex is behind the latest version
    And its update command does not finish within five minutes
    When the user updates Codex
    Then the update fails as timed out

  @backlog @mc
  Scenario: A failed update command reports its exit code and output
    Given Codex is behind the latest version
    And its update command exits with code 1 and prints an error
    When the user updates Codex
    Then the update fails naming exit code 1
    And the update's result carries the command's error output

  @backlog @mc
  Scenario: An update's output is capped
    Given Codex is behind the latest version
    And its update command prints far more than ten thousand characters
    When the user updates Codex
    Then the update's result carries only the first ten thousand characters of that output

  @backlog @mc
  Scenario: An update to a version that is no longer recommended is refused
    Given the user asked to install the recommended "0.1.5" of Codex
    And "0.1.5" stopped being the recommended version before the update ran
    When the update starts
    Then the update fails telling the user to refresh provider settings
    And no update command is run

  @backlog @mc
  Scenario Outline: An update to a latest release that turned incompatible is refused when it runs
    Given Codex is behind the latest version
    And that latest release was marked <status> for this HAL-C2 release after the last check
    When the user updates Codex
    Then the update fails saying the latest version is incompatible with this HAL-C2 release
    And no update command is run

    Examples:
      | status      |
      | unsupported |
      | broken      |

  @backlog @mc
  Scenario: An update that cannot be verified is reported as unchanged
    Given Codex is behind the latest version
    And its update command succeeds but the provider's version cannot be read afterwards
    When the user updates Codex
    Then the user is told the update finished but the version could not be verified

  @backlog @mc
  Scenario: A second update for the same provider is refused while one runs
    Given a Codex update is running
    When the user updates Codex again
    Then the second update is refused saying an update is already running for that provider

  Scenario Outline: A provider version outside the supported range is flagged
    Given the installed provider version is <status> for this HAL-C2 release
    When the user opens the provider list
    Then the provider shows "<title>"

    Examples:
      | status              | title                 |
      | of limited support  | Limited support       |
      | unsupported         | Unsupported version   |
      | known to be broken  | Known broken version  |

  Scenario: No update is offered when the latest release is itself incompatible
    Given Codex is behind the latest release
    And that latest release is known to be broken with this HAL-C2 release
    When the user opens the provider list
    Then Codex is not offered an update to that release

  # Antigravity is the one provider whose runtime the MC installs itself
  # (apps/server/src/provider/AntigravityInstallation.ts, installation.ex).
  @plugin-antigravity
  Scenario: A managed runtime reports install progress to every client
    Given Antigravity is enabled on that environment
    And two clients are connected to the MC
    When the user installs a managed provider runtime on one client
    Then both clients show the download progress

  @plugin-antigravity
  Scenario: A managed installation can be cancelled
    Given Antigravity is enabled on that environment
    And a managed provider runtime is downloading
    When the user cancels the installation
    Then the download stops and the previous runtime is unchanged

  @plugin-antigravity
  Scenario: A managed runtime can be removed and installed again
    Given Antigravity is enabled on that environment
    And a managed provider runtime is installed and not in use
    When the user removes it
    Then the provider shows that it is not installed
    When the user installs it again
    Then the provider is installed

  @backlog @mobile
  Scenario: The mobile app lists providers that can sign in from HAL-C2
    When the user opens provider accounts on the mobile app
    Then only providers with in-app sign-in are listed, per device

  @mobile @backlog-mobile
  Scenario: Answering a terminal sign-in from the mobile app
    Given a terminal sign-in for an ACP agent is waiting for input
    When the user sends a response from the mobile app
    Then the response reaches the sign-in terminal on the MC

  @desktop @mobile @backlog-mobile
  Scenario: Signing out asks for confirmation and keeps history
    Given the user is signed in to an ACP agent
    When the user signs out and confirms
    Then running threads sharing that sign-in stop
    And thread history is kept

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario: The signed-in email is hidden until the user reveals it
    Given a provider is signed in as "me@example.com"
    When the user opens the provider
    Then the account is shown as signed in with the email hidden
    When the user reveals the email
    Then "me@example.com" is shown
