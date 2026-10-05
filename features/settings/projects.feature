# Sources:
#   docs/user/project-settings.md (Project category, mobile Overview, project icons)
#   apps/web/src/components/settings/ProjectsSettings.tsx
#   apps/web/src/components/settings/ProjectSettingsPanel.tsx
#   apps/web/src/components/settings/ProjectSettingsPanel.logic.ts
#   apps/web/src/shell/HalC2ShellBridge.tsx (project.remove)
#   apps/tui/src/features.backlog.test.ts (project-lifecycle)
#   packages/contracts/src/rpc.ts (projects.mutate)

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

  @desktop @mobile @tui @backlog-mobile @backlog-tui
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

  @desktop @mobile @backlog-mobile
  Scenario: The icon of a project is chosen and reset from the panel
    When the user chooses the emoji "🛒" as the icon of "shop" in settings
    Then "shop" shows "🛒" on every checkout
    When the user sets the icon of "shop" back to automatic
    Then "shop" shows its automatic icon

  @desktop @mobile @backlog-mobile
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
