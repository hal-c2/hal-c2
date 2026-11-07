# Sources:
#   https://github.com/pingdotgg/t3code/pull/20386
#   https://github.com/pingdotgg/t3code/pull/18110
#   https://github.com/pingdotgg/t3code/pull/20796
#   https://github.com/pingdotgg/t3code/pull/14295
#   https://github.com/pingdotgg/t3code/pull/19580
#   https://github.com/pingdotgg/t3code/pull/21451
#   https://github.com/pingdotgg/t3code/pull/21452
#   https://github.com/pingdotgg/t3code/pull/19157
#   https://github.com/pingdotgg/t3code/pull/19887
#   https://github.com/pingdotgg/t3code/pull/18851
#   https://github.com/pingdotgg/t3code/pull/18425
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
#   https://github.com/pingdotgg/t3code/pull/15416
#   https://github.com/pingdotgg/t3code/pull/15539
#   https://github.com/pingdotgg/t3code/pull/15501

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

  # Upstream #18851: disabled providers skip periodic health checks; manual refresh and enabling still check them.
  @backlog
  Scenario: A disabled provider is not checked on a schedule
    Given Grok is disabled and a client is watching provider status
    When the periodic provider check runs
    Then Grok is not checked and no status is sent for it
    When the user refreshes providers
    Then Grok is checked
    When the user enables Grok
    Then Grok is checked at once and on the schedule after that

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

  # Upstream #18110: a provider that is behind with no update command says which version is
  # out and asks the user to update the executable it names with whatever installed it.
  @backlog @desktop
  Scenario: A provider behind with no update command says how to update it
    Given Codex's executable is a package inside a project's node_modules
    And a newer Codex is out
    When the user looks at Codex's update details
    Then the user is told the newer version is out
    And the user is told to update the executable at that path with the app or tool that installed it

  # Ownership is proven from where the executable really lives, never from a name
  # (apps/server/src/provider/providerMaintenance.ts resolvePackageManagedProviderMaintenance).
  # Upstream #19887: Vite+ provider installs get update prompts, Windows included.
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

  # Upstream #14295: pnpm global updates install the advertised version rather than "latest".
  @backlog @priority-low
  Scenario: A pnpm global update installs the version it advertised
    Given Codex's executable lives in a pnpm global install
    And Codex "0.2.0" is advertised as the latest version
    When the user updates Codex
    Then pnpm is asked to install Codex "0.2.0" and not "latest"
    And the copyable update command names "0.2.0" too

  # Upstream #20796: on pnpm 10.4 or newer a pnpm global update allows the provider package's
  # install script, which pnpm otherwise skips silently.
  @backlog @priority-low
  Scenario: A pnpm global update lets the provider finish installing
    Given OpenCode was installed as a pnpm global package with pnpm 10.4 or newer
    When the user updates OpenCode
    Then OpenCode's install script runs as part of the update
    And OpenCode is usable afterwards

  @backlog @mc @priority-low
  Scenario: A package inside a project folder is not a global install
    Given Codex's executable is a package inside a project's node_modules
    When the user opens Codex's update details
    Then no update command is offered for Codex

  @backlog @mc @priority-low
  Scenario: A Node installed by Homebrew still updates its global packages through npm
    Given Codex was installed with npm into a Node that Homebrew installed
    When the user opens Codex's update details
    Then the update command runs npm and not Homebrew

  @backlog @mc @priority-low
  Scenario: A Homebrew keg outside the Homebrew that would run the upgrade is not updated by it
    Given Codex's executable sits in a Homebrew keg under a different prefix than the brew on the path
    When the user opens Codex's update details
    Then no update command is offered for Codex

  @backlog @mc @priority-low
  Scenario: A version manager's shim is never updated through Homebrew
    Given Codex's executable is a shim that resolves into Homebrew's mise
    When the user opens Codex's update details
    Then no update command is offered for Codex

  # Upstream #19157: a provider launcher mise owns in a native install location gets mise's update, not the native updater.
  @backlog
  Scenario: A mise launcher in a native install location is updated through mise
    Given Claude's launcher sits in its native install location but is owned by mise
    When an update for Claude is available
    Then the update is offered through mise
    And the native updater is not run

  @backlog @mc
  Scenario: A provider's own updater targets the home that instance uses
    Given Codex was installed by its own installer
    And this Codex instance uses its own provider home
    When the user updates Codex
    Then Codex's updater runs against that home and not the default one

  @backlog @mc @priority-low
  Scenario: The update command is copyable as written
    Given Codex's executable path contains spaces
    When the user opens Codex's update details
    Then the update command quotes that path so it can be pasted into a shell

  @backlog @mc @priority-low
  Scenario: The installer's own answer decides whether a newer Homebrew version exists
    Given Codex was installed with Homebrew
    And npm already has a release that Homebrew has not published yet
    When the MC checks provider versions
    Then Codex is compared against the version Homebrew would install

  # Upstream #21451: refreshing a provider reused cached Homebrew metadata; an explicit refresh now
  # rereads it, background checks keep the cache.
  @backlog @priority-low
  Scenario: Refreshing a provider rereads what its installer knows
    Given Codex was installed with Homebrew and upgraded outside HAL-C2
    When the user refreshes Codex's status
    Then the installed and latest versions are read anew from Homebrew
    And background checks keep using the cached answer

  @backlog @mc @priority-low
  Scenario: A Homebrew install whose latest version cannot be read shows no update
    Given Codex was installed with Homebrew
    And Homebrew does not answer within ten seconds
    When the MC checks provider versions
    Then Codex's update status is unknown

  # Upstream #19580: a pnpm install was offered the registry's newest version even when pnpm
  # would not install it; the offer now follows pnpm's own answer.
  @backlog @priority-low
  Scenario: A pnpm install is compared against the version pnpm will install
    Given Codex was installed globally with pnpm
    And the registry's newest Codex is one pnpm will not install yet
    When the MC checks Codex for updates
    Then only a version pnpm will install is offered

  # Upstream #20386: a Homebrew cask without a version is not offered an update.
  @backlog @priority-low
  Scenario: A Homebrew cask with no version of its own shows no update
    Given Pi was installed from a Homebrew cask whose version is "latest"
    When the MC checks provider versions
    Then Pi's update status is unknown
    And no update to a version called "latest" is offered

  @backlog @mc @priority-low
  Scenario: Latest versions are looked up at most once an hour per package
    Given Codex was installed with npm
    When the MC checks provider versions twice within an hour
    Then the registry is asked for the latest Codex version once

  @backlog @mc @priority-low
  Scenario: A registry that does not answer leaves the update status unknown
    Given Codex was installed with npm
    And the package registry does not answer within four seconds
    When the MC checks provider versions
    Then Codex's update status is unknown
    And no error is shown to the user

  @backlog @mc @priority-low
  Scenario Outline: A provider that cannot be updated yet is not checked against the registry
    Given Codex is <state>
    When the MC checks provider versions
    Then no latest version is looked up for Codex

    Examples:
      | state                            |
      | disabled                         |
      | not installed                    |
      | installed but reports no version |

  # Codex's ChatGPT sign-in from HAL-C2 is @backlog in codex.feature ("Codex connects a
  # ChatGPT account from HAL-C2"); this line describes today's behaviour and must be reconciled then.
  # Upstream #18425: providers whose CLI owns setup declare they cannot be installed or signed in from the app.
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

  @backlog @mc @priority-high
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

  @backlog @mc @priority-low
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

  # Upstream #21452: Homebrew reporting the same incompatible release as installed and latest left
  # no recovery; the provider now shows the Homebrew commands to run.
  @backlog @priority-low
  Scenario: A Homebrew install stuck on an incompatible release says how to get past it
    Given Codex was installed with Homebrew
    And Homebrew reports the installed Codex and its latest Codex as the same unsupported release
    When the user opens the provider list
    Then Codex shows the Homebrew commands to refresh and upgrade it on the environment's machine
    And the hint goes once a compatible latest release is found

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

  @desktop @mobile @backlog-mobile @backlog-mc @priority-low
  Scenario: The signed-in email is hidden until the user reveals it
    Given a provider is signed in as "me@example.com"
    When the user opens the provider
    Then the account is shown as signed in with the email hidden
    When the user reveals the email
    Then "me@example.com" is shown

  # Upstream #15416: a provider no package manager is proven for falls back to its own updater
  @backlog
  Scenario: A provider installed by its own installer is updated by its own updater
    Given a provider whose package manager cannot be proven
    When the user updates it
    Then the MC runs the provider's own update command
    And a version check afterwards reports an updater that exited without updating

  # Upstream #15539: the copied update command matches the installed CLI
  @backlog @shared
  Scenario: The copied update command matches how the MC was installed
    Given the MC runs from a global package install
    When the user copies the update command
    Then the command updates that installation rather than starting a cached copy
    And an install it cannot identify copies a relaunch command saying that it does not update the installed MC

  # Upstream #15501: both update icons open the version details
  @backlog @shared @priority-low
  Scenario: Wherever a provider offers an update, its version details open
    Given a provider with an update available
    When the user selects the update offer in either place it shows
    Then the version details open, with copy and update as separate actions
    And a read-only connection can read and copy but not update
