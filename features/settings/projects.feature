# Sources:
#   https://github.com/pingdotgg/t3code/pull/18901
#   https://github.com/pingdotgg/t3code/pull/17860
#   docs/user/project-settings.md (Project category, mobile Overview, project icons)
#   apps/web/src/components/settings/ProjectsSettings.tsx
#   apps/web/src/components/settings/ProjectSettingsPanel.tsx
#   apps/web/src/components/settings/ProjectSettingsPanel.logic.ts
#   apps/web/src/shell/HalC2ShellBridge.tsx (project.remove)
#   apps/tui/src/features.backlog.test.ts (project-lifecycle)
#   packages/contracts/src/rpc.ts (projects.mutate)
#   https://github.com/pingdotgg/t3code/pull/14490
#   https://github.com/pingdotgg/t3code/pull/14527
#   https://github.com/pingdotgg/t3code/pull/14635

Feature: Projects settings panel
  The Projects panel manages one project across its checkouts: its name, its icon, its
  checkouts, and removing it. The behaviour behind each control lives in the files domain.

  Background:
    Given the user has the project "shop" with checkouts on "laptop" and "server"
    And both environments are connected

  @desktop
  Scenario: The panel asks the user to pick a project first
    When the user opens the Projects settings without a project picked
    Then the user is asked to choose a project to manage its name, icon, checkouts and actions

  @desktop
  Scenario: The panel explains how to add a first project
    Given the user has no projects
    When the user opens the Projects settings
    Then the user is told to add a project from the sidebar to configure it here

  @desktop
  Scenario: A project removed elsewhere is reported as no longer available
    Given the user is managing "shop" in settings
    When "shop" is removed on another device
    Then the user is told this project is no longer available

  @desktop
  Scenario: A checkout that disappears is reported as no longer available
    Given the user is managing the "server" checkout of "shop"
    When that checkout is removed on another device
    Then the user is told this checkout is no longer available in the selected project and environment

  @desktop
  Scenario: The panel keeps following the project when grouping changes
    Given the user is managing "shop" in settings
    When the user changes how projects are grouped
    Then the panel still shows "shop"

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: Renaming a project renames every checkout
    When the user renames "shop" to "Shop web" in settings
    Then "Shop web" is shown for the checkouts on "laptop" and "server"

  @desktop @mobile @tui @backlog-mobile @backlog-tui @priority-low
  Scenario: A project name cannot be empty
    When the user clears the name of "shop" in settings
    Then the user is told the project title cannot be empty
    And the name stays "shop"

  @desktop @mobile @backlog-mobile
  Scenario: Renaming with a disconnected checkout asks the user to reconnect
    Given "server" is disconnected
    When the user renames "shop" to "Shop web" in settings
    Then the user is told to connect "server" and try again

  @desktop @mobile @backlog-mobile
  Scenario: A rename that fails on one environment names that environment
    Given renaming fails on "server"
    When the user renames "shop" to "Shop web" in settings
    Then the user is told the rename failed on "server"

  @desktop @mobile @backlog-mobile @priority-low
  Scenario: The icon of a project is chosen and reset from the panel
    When the user chooses the emoji "🛒" as the icon of "shop" in settings
    Then "shop" shows "🛒" on every checkout
    When the user sets the icon of "shop" back to automatic
    Then "shop" shows its automatic icon

  @desktop @mobile @backlog-mobile @priority-low
  Scenario: The panel lists every checkout with where it lives
    When the user manages "shop" in settings
    Then the checkouts on "laptop" and "server" are listed with their folders

  @desktop
  Scenario: Removing one checkout keeps the others
    When the user removes the "server" checkout of "shop" and confirms
    Then "shop" is listed only on "laptop"

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: Removing a project everywhere removes every checkout
    When the user removes "shop" everywhere and confirms
    Then "shop" is no longer listed on "laptop" or "server"
    And no files are deleted on either machine

  @desktop
  Scenario: The removal confirmation names what will be cleared
    Given the "laptop" checkout of "shop" has 3 threads
    When the user asks to remove the "laptop" checkout of "shop"
    Then the confirmation names 3 threads, the folder and "laptop"
    And the confirmation says conversation history is cleared permanently

  @desktop
  Scenario: Removing from the desktop folder explorer opens the removal in settings
    When the user removes a registered folder from HAL-C2 in the folder explorer
    Then the Projects settings open with the removal confirmation for that project

  @desktop
  Scenario: Cancelling a removal requested from the folder explorer leaves the project
    Given the user asked to remove "shop" from the folder explorer
    When the user cancels the removal in settings
    Then "shop" is still listed

  @desktop
  Scenario: The panel points to other project settings
    When the user manages "shop" in settings
    Then the user is told to keep the project picked while browsing other pages to find more of its settings

  @backlog @shared
  Scenario: Add project offers only connected environments
    Given one environment is connected and another is switched off in Connections
    When the user starts Add project
    Then the switched-off environment is not offered
    And with a single connected environment the chooser is skipped

  @backlog @shared
  Scenario: Add project with no connected environment points at Connections
    Given every environment is switched off
    When the user starts Add project
    Then the user is directed to Connections

  @backlog @shared @mc
  Scenario: A new project is started from just a name
    Given a connected environment
    When the user chooses New project and types "Pinball Stats"
    Then the MC creates a folder "pinball-stats" under its projects directory with a README, an icon and a first commit
    And the project is titled "Pinball Stats"
    And a new thread opens in it

  @backlog @mc
  Scenario: A taken project folder gets a numeric suffix
    Given a new project "Pinball Stats" already exists
    When the user creates another new project named "Pinball Stats"
    Then its folder is "pinball-stats-2"

  @backlog @mc
  Scenario: A new project survives a failed first commit
    Given Git has no user name or email
    When the user creates a new project
    Then the project is still created
    And a warning says why the first commit failed

  @backlog @shared @priority-low
  Scenario: The new project name step names the machine
    Given more than one environment is connected
    When the user opens the New project name step
    Then it lists the machines and the path line names the one chosen
    And switching machine keeps the typed name

  @backlog @shared
  Scenario: A new project can also be published as a private repository
    Given GitHub is signed in
    When the user creates a new project with "Create private repository on GitHub" on
    Then the repository is published after the project is created

  @backlog @shared
  Scenario: mod+Enter creates the new project while an option is highlighted
    Given the user typed a name in the New project step
    And "Create private repository on GitHub" is highlighted
    Then the create button offers mod+Enter
    When the user presses mod+Enter
    Then the project is created and the option is left as it was
    But pressing Enter alone toggles the highlighted option

  @backlog @shared @mobile
  Scenario: A new project can be published to any ready host
    Given GitHub and GitLab are both signed in
    When the user creates a new project with publishing on
    Then the user can pick GitHub or GitLab, with GitHub first
    And the repository is published to the chosen host, and the messages name it

  @backlog @shared @mobile
  Scenario Outline: A host is offered for a new project only when it can say where the repository goes
    Given <host> is signed in <how>
    When the user creates a new project with publishing on
    Then <host> is <offered>

    Examples:
      | host         | how                                     | offered     |
      | Forgejo      | with an account                         | offered     |
      | Bitbucket    | with an API token that names no username | not offered |
      | Azure DevOps | with an account                         | not offered |

  @backlog @mc @priority-low
  Scenario: A cloned project shows its favicon at once
    Given a repository with a favicon is being cloned as a project
    When the clone finishes
    Then the project shows the repository's favicon instead of a generated monogram
    And no reload is needed
