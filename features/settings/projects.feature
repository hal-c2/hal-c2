# Sources:
#   https://github.com/pingdotgg/t3code/pull/29917
#   https://github.com/pingdotgg/t3code/pull/23641
#   https://github.com/pingdotgg/t3code/pull/26154
#   https://github.com/pingdotgg/t3code/pull/23231
#   https://github.com/pingdotgg/t3code/pull/26798
#   https://github.com/pingdotgg/t3code/pull/18692
#   https://github.com/pingdotgg/t3code/pull/20231
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
#   https://github.com/pingdotgg/t3code/pull/21409

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

  # Upstream #18692: picking an environment without the project replaced the page with a dead end.
  @backlog @desktop
  Scenario: The environments offered for a project are the ones that have it
    Given the environment "spare" has no checkout of "shop"
    When the user picks the environment for "shop" in the Projects settings
    Then "laptop" and "server" are offered and "spare" is not

  # Upstream #18692: a stale link to a project on an environment without it kept no way back.
  @backlog @desktop
  Scenario: A project unavailable on the picked environment keeps the way back
    Given the user opens the Projects settings for "shop" on an environment without it
    Then the user is told why "shop" is unavailable there
    And the project and environment pickers are still shown
    And showing all environments keeps "shop" picked

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

  # Upstream #23231: Enter that confirmed an input method's candidate saved the half-typed name
  # and took the keyboard away from the field.
  @backlog @desktop @priority-low
  Scenario: Confirming an input method's candidate keeps the project name open for editing
    Given the user is renaming "shop" in settings with a Japanese input method
    When the user presses Enter to pick a candidate
    Then the name is not saved yet and the field keeps the keyboard
    When the user finishes the name and presses Enter
    Then the finished name is saved

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

  # Upstream #26798: a renamed "No project" had no name reset, and clearing its icon lost its own.
  @backlog @desktop @mobile @priority-low
  Scenario: A renamed "No project" can be reset to its own name and icon
    Given the user renamed "No project" to "Notes" and gave it a rocket icon
    When the user resets its name and its icon in settings
    Then it is called "No project" again and shows its own icon

  @desktop @mobile @backlog-mobile @priority-low
  Scenario: The panel lists every checkout with where it lives
    When the user manages "shop" in settings
    Then the checkouts on "laptop" and "server" are listed with their folders

  # Upstream #23641: with related checkouts grouped, the panel had no per-checkout grouping, so a
  # checkout could not be split into its own project there or put back under the global rule.
  @backlog @desktop @mobile @priority-low
  Scenario: A checkout's grouping is set and reset from the panel
    Given project grouping combines matching repositories
    When the user sets the "server" checkout of "shop" to stay apart
    Then the "server" checkout is listed as a project of its own and the panel follows it
    When the user sets it back to follow the global grouping
    Then it is grouped into "shop" again and the checkout's other overrides are kept
    And a grouping that cannot be saved is reported and the saved choice stays shown

  # Upstream #21409: the phone lists projects and checkouts and can now remove them too.
  @desktop @mobile @backlog-mobile
  Scenario: Removing one checkout keeps the others
    When the user removes the "server" checkout of "shop" and confirms
    Then "shop" is listed only on "laptop"

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: Removing a project everywhere removes every checkout
    When the user removes "shop" everywhere and confirms
    Then "shop" is no longer listed on "laptop" or "server"
    And no files are deleted on either machine

  # Upstream #21409
  @desktop @mobile @backlog-mobile
  Scenario: The removal confirmation names what will be cleared
    Given the "laptop" checkout of "shop" has 3 threads
    When the user asks to remove the "laptop" checkout of "shop"
    Then the confirmation names 3 threads, the folder and "laptop"
    And the confirmation says conversation history is cleared permanently

  # Upstream #29917: the count included side chats and subagent threads, which no thread list
  # shows, and moved as subagents started and went idle.
  @backlog @desktop @mobile
  Scenario: The removal confirmation counts only the threads the lists show
    Given the "laptop" checkout of "shop" has 1 thread with a side chat and a running subagent
    When the user asks to remove the "laptop" checkout of "shop"
    Then the confirmation names 1 thread
    And the side chat and the subagent are removed with that thread

  # Upstream #21409: after removal the phone left a dead screen and kept filtering by the project.
  @backlog @mobile
  Scenario: Removing a project on the phone goes back and clears its drafts
    Given the user filtered the phone's project settings to "shop" and has an unsent draft in "shop"
    When the user removes "shop" everywhere and confirms
    Then the phone goes back to the project list, no longer filtered by "shop"
    And the unsent draft in "shop" is gone

  # Upstream #20231: removing a project returns to the project overview and keeps the chosen environment.
  @backlog @desktop
  Scenario: Removing a project returns to the project list
    Given the user is looking at the "laptop" checkout of "shop" in the Projects settings
    When the user removes it and confirms
    Then the Projects settings list the remaining projects
    And "laptop" is still the environment shown

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

  # Upstream #14490: Add project hides disconnected environments
  @backlog @shared
  Scenario: Add project offers only connected environments
    Given one environment is connected and another is switched off in Connections
    When the user starts Add project
    Then the switched-off environment is not offered
    And with a single connected environment the chooser is skipped

  # Upstream #14490: Add project with no connected environment points at Connections
  @backlog @shared
  Scenario: Add project with no connected environment points at Connections
    Given every environment is switched off
    When the user starts Add project
    Then the user is directed to Connections

  # Upstream #14527: start a new project from just a name
  @backlog @shared @mc
  Scenario: A new project is started from just a name
    Given a connected environment
    When the user chooses New project and types "Pinball Stats"
    Then the MC creates a folder "pinball-stats" under its projects directory with a README, an icon and a first commit
    And the project is titled "Pinball Stats"
    And a new thread opens in it

  # Upstream #14527: start a new project from just a name
  @backlog @mc
  Scenario: A taken project folder gets a numeric suffix
    Given a new project "Pinball Stats" already exists
    When the user creates another new project named "Pinball Stats"
    Then its folder is "pinball-stats-2"

  # Upstream #14527: start a new project from just a name
  @backlog @mc
  Scenario: A new project survives a failed first commit
    Given Git has no user name or email
    When the user creates a new project
    Then the project is still created
    And a warning says why the first commit failed

  # Upstream #14527: start a new project from just a name
  @backlog @shared @priority-low
  Scenario: The new project name step names the machine
    Given more than one environment is connected
    When the user opens the New project name step
    Then it lists the machines and the path line names the one chosen
    And switching machine keeps the typed name

  # Upstream #14527: start a new project from just a name
  @backlog @shared
  Scenario: A new project can also be published as a private repository
    Given GitHub is signed in
    When the user creates a new project with "Create private repository on GitHub" on
    Then the repository is published after the project is created

  # Upstream #18901: Cmd+Enter creates the project while an option is highlighted
  @backlog @shared @priority-low
  Scenario: mod+Enter creates the new project while an option is highlighted
    Given the user typed a name in the New project step
    And "Create private repository on GitHub" is highlighted
    Then the create button offers mod+Enter
    When the user presses mod+Enter
    Then the project is created and the option is left as it was
    But pressing Enter alone toggles the highlighted option

  # Upstream #17860: a new project can be published to any ready host
  @backlog @shared @mobile
  Scenario: A new project can be published to any ready host
    Given GitHub and GitLab are both signed in
    When the user creates a new project with publishing on
    Then the user can pick GitHub or GitLab, with GitHub first
    And the repository is published to the chosen host, and the messages name it

  # Upstream #17860: only hosts that can say where the repository goes are offered
  @backlog @shared @mobile @priority-low
  Scenario Outline: A host is offered for a new project only when it can say where the repository goes
    Given <host> is signed in <how>
    When the user creates a new project with publishing on
    Then <host> is <offered>

    Examples:
      | host         | how                                     | offered     |
      | Forgejo      | with an account                         | offered     |
      | Bitbucket    | with an API token that names no username | not offered |
      | Azure DevOps | with an account                         | not offered |

  # Upstream #14635: cloned projects show their favicon instead of a monogram
  @backlog @mc @priority-low
  Scenario: A cloned project shows its favicon at once
    Given a repository with a favicon is being cloned as a project
    When the clone finishes
    Then the project shows the repository's favicon instead of a generated monogram
    And no reload is needed

  # Upstream #26154: projects piled up with no way to keep favourites first or hide finished ones.
  @backlog @mc @shared @priority-high
  Rule: Pinned projects come first and archived projects leave the pickers

    Scenario: A pinned project comes first in every project picker
      Given the projects "api", "shop" and "web"
      When the user pins "web"
      Then "web" is listed first in the sidebar's project filter, the new thread's project choice, the command palette and scheduled tasks
      And the other projects keep the user's project order

    Scenario: A pinned project keeps its folder in the sidebar without active threads
      Given "web" is pinned and has no active threads
      When the user looks at the sidebar
      Then "web" has a folder above the other projects, with its new-thread button
      And the user can pin or unpin a folder from its menu

    Scenario Outline: A project is pinned and unpinned from where it is chosen
      When the user pins "web" from <where>
      Then "web" is pinned
      And the same place unpins it

      Examples:
        | where                                                                |
        | its row in a new thread's project choice                             |
        | the new-thread project list, with mod+shift+p on the highlighted row |
        | the command palette                                                  |
        | the sidebar's project filter                                         |
        | Settings > Projects                                                  |

    Scenario: An archived project leaves the pickers and keeps its threads
      When the user archives "api" in Settings > Projects
      Then "api" is no longer offered in the project pickers
      And its threads, settings and files are kept
      And Settings lists "api" marked "Archived", with "Unarchive" on its page

    Scenario: An archived project with active threads keeps a folder below the open projects
      Given "api" is archived and has an active thread
      When the user looks at the sidebar
      Then "api" has a folder below the open projects

    Scenario: Adding an archived project's folder again unarchives it
      Given "api" is archived
      When the user adds the folder of "api" as a project from the command palette, the phone or the desktop
      Then "api" is no longer archived

    @mobile
    Scenario: The phone pins and archives from Organize
      When the user opens Settings > Projects > Organize
      Then each project can be pinned and archived there

    Scenario: A project on several machines is pinned if any machine says so and archived only if every one does
      Given "shop" has checkouts on "laptop" and "server"
      And "laptop" has "shop" pinned and archived but "server" has neither
      When the user looks at the project pickers
      Then "shop" is listed, pinned

    Scenario: An agent pins and archives a project with its project tool
      When an agent updates "api" through the HAL-C2 project tool with pinned and archived set
      Then "api" is pinned and archived

    Scenario: An MC that cannot keep pins and archives offers neither
      Given an environment whose MC does not keep project pins and archives
      When the user looks at its projects
      Then no pin or archive control is offered for them
