# Sources:
#   docs/user/project-settings.md (Project category, removal)
#   apps/server-ex/lib/hal_c2/projects.ex (project.update, project.delete, auto_pull)
#   apps/web/src/components/settings/ProjectsSettings.tsx (removal)
#   apps/desktop-qt/src/native/ProjectController.cpp (project.remove, the confirmation, projects.mutate)
#   apps/desktop-qt/qml/HalC2/Bricks/ProjectRemovalDialog.qml
#   apps/desktop-qt/qml/HalC2/Bricks/FolderExplorer.qml (Remove from HAL-C2)
#   apps/tui/src/features.backlog.test.ts (project-lifecycle)
#   packages/contracts/src/project.ts (project.update, project.delete, autoPull)
#   packages/contracts/src/rpc.ts (projects.mutate; projects.list and projects.remove are
#     unrouted names, dropped in parity/rpc.feature)
#   apps/server/src/cli/project.ts (hal-c2 project add, remove, rename; live server or stored state)

Feature: Removing and updating projects
  A project entry can be renamed, changed, and removed. Removing a project clears its
  conversations from HAL-C2 but never deletes files on disk.

  Background:
    Given a connected environment "laptop" with the project "shop" at "/home/sam/shop"

  @mc
  Scenario: Updating a project changes only the fields that were sent
    Given "shop" has the default model "Sonnet"
    When a client renames "shop" to "Shop web"
    Then the project is titled "Shop web"
    And its default model is still "Sonnet"

  @mc
  Scenario: Deleting a project removes it from every sidebar
    When a client deletes the project "shop"
    Then "shop" is no longer listed for "laptop"
    And "/home/sam/shop" still exists on disk

  @mc
  Scenario: Changing a project that does not exist fails
    When a client renames an unknown project
    Then the MC answers "unknown project"

  @desktop @mobile @tui @backlog-mobile
  Scenario: Removing a project asks for confirmation and explains what is lost
    Given "shop" has 4 threads
    When the user asks to remove "shop"
    Then the user is told 4 threads and their conversation history will be cleared
    And the user is told the files on disk are kept

  @desktop @mobile @tui @backlog-mobile
  Scenario: Confirming removal clears the project and its drafts
    Given "shop" has an unsent draft
    When the user confirms removing "shop"
    Then "shop" is no longer listed for "laptop"
    And the draft for "shop" is gone

  @desktop @mobile @tui @backlog-mobile
  Scenario: Cancelling removal keeps the project
    When the user asks to remove "shop"
    And the user cancels
    Then "shop" is still listed for "laptop"

  @desktop
  Scenario: A confirmation for a project that goes away closes
    Given the user asks to remove "shop"
    When the MC removes the project "shop"
    Then the removal confirmation is closed

  @desktop @mobile @tui @backlog-mobile
  Scenario: A removal the environment refuses keeps the project and says why
    Given the environment refuses to change projects with "Project shop is busy."
    When the user confirms removing "shop"
    Then the user sees an "error" toast "Failed to remove project" saying "Project shop is busy."
    And "shop" is still listed for "laptop"

  @desktop
  Scenario: Removing the project the user is looking at returns home
    Given the user is looking at a thread in "shop"
    When the user confirms removing "shop" everywhere
    Then the user is taken home

  @desktop
  Scenario: Removing a registered folder from the folder explorer asks through project settings
    Given the folder explorer shows "/home/sam/shop"
    When the user removes "/home/sam/shop" from HAL-C2
    Then the removal confirmation for "shop" on "laptop" opens

  Rule: Automatic pull at startup

    @mc
    Scenario: A clean checkout behind its upstream is pulled when the MC starts
      Given "shop" has automatic pull on
      And "shop" is a clean checkout of its default branch that is behind its upstream
      When the MC starts
      Then "shop" is fast-forwarded to its upstream

    @mc
    Scenario Outline: Checkouts that are not safe to pull are left alone
      Given "shop" has automatic pull on
      And "shop" <state>
      When the MC starts
      Then "shop" is not pulled
      And the MC starts normally

      Examples:
        | state                                  |
        | has uncommitted changes                |
        | is on a branch other than its default  |
        | has no upstream                        |
        | has commits its upstream does not have |

    @mc
    Scenario: Automatic pull is off unless the project opts in
      Given "shop" is a clean checkout behind its upstream
      And automatic pull was never turned on for "shop"
      When the MC starts
      Then "shop" is not pulled

  Rule: Managing projects from the command line

    @backlog @mc
    Scenario: A folder is added as a project from the command line
      When the operator runs "hal-c2 project add ~/code/api"
      Then the project "api" is listed for "laptop"
      And the command prints the new project's id, title and folder

    @backlog @mc
    Scenario: A project added from the command line can be given a title
      When the operator runs "hal-c2 project add ~/code/api --title 'API server'"
      Then the project "API server" is listed for "laptop"

    @backlog @mc
    Scenario: A folder that is already a project is not added twice
      When the operator runs "hal-c2 project add /home/sam/shop"
      Then the command fails saying an active project already exists for "/home/sam/shop"
      And "shop" is still the only project at that folder

    @backlog @mc
    Scenario Outline: An empty title is refused from the command line
      When the operator <command>
      Then the command fails saying the project title cannot be empty
      And no project changes

      Examples:
        | command                                        |
        | runs "hal-c2 project add ~/code/api --title ' '" |
        | runs "hal-c2 project rename shop ' '"          |

    @backlog @mc
    Scenario Outline: A project is named on the command line by its id or its folder
      When the operator runs "hal-c2 project rename <project> 'Shop web'"
      Then the project at "/home/sam/shop" is titled "Shop web"

      Examples:
        | project         |
        | its project id  |
        | /home/sam/shop  |

    @backlog @mc
    Scenario: A project whose folder is gone can still be named by its folder
      Given the folder "/home/sam/shop" no longer exists
      When the operator runs "hal-c2 project remove /home/sam/shop"
      Then "shop" is no longer listed for "laptop"

    @backlog @mc
    Scenario: Renaming a project to its own title changes nothing
      When the operator runs "hal-c2 project rename shop shop"
      Then the command says "shop" is already named that
      And no change is made

    @backlog @mc
    Scenario: A project that does not exist is reported by name
      When the operator runs "hal-c2 project remove /home/sam/nothing"
      Then the command fails saying no active project was found for "/home/sam/nothing"

    @backlog @mc
    Scenario: Removing a project that has threads needs force
      Given "shop" has threads
      When the operator runs "hal-c2 project remove shop"
      Then the command fails and "shop" keeps its threads
      When the operator runs "hal-c2 project remove shop --force"
      Then "shop" and its threads are removed
      But the files in "/home/sam/shop" are untouched

    @backlog @mc
    Scenario: A running MC applies a project command and its clients see it at once
      Given a client is watching the project list
      When the operator runs "hal-c2 project add ~/code/api"
      Then the client sees "api" appear without reloading

    @backlog @mc
    Scenario: With the MC stopped a project command changes the stored projects
      Given the MC is not running
      When the operator runs "hal-c2 project add ~/code/api"
      Then "api" is listed once the MC starts
