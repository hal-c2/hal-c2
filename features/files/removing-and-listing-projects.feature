# Sources:
#   docs/user/project-settings.md (Project category, removal)
#   apps/server-ex/lib/t3/projects.ex (project.update, project.delete, auto_pull)
#   apps/web/src/components/settings/ProjectsSettings.tsx (removal)
#   apps/web/src/shell/T3ShellBridge.tsx (project.remove)
#   apps/desktop-qt/qml/T3/Bricks/FolderExplorer.qml (Remove from T3)
#   apps/tui/src/features.backlog.test.ts (project-lifecycle)
#   packages/contracts/src/project.ts (project.update, project.delete, autoPull)
#   packages/contracts/src/rpc.ts (projects.mutate; projects.list and projects.remove are
#     unrouted names, dropped in parity/rpc.feature)

Feature: Removing and updating projects
  A project entry can be renamed, changed, and removed. Removing a project clears its
  conversations from T3 Code but never deletes files on disk.

  Background:
    Given a connected environment "laptop" with the project "shop" at "/home/sam/shop"

  @node
  Scenario: Updating a project changes only the fields that were sent
    Given "shop" has the default model "Sonnet"
    When a client renames "shop" to "Shop web"
    Then the project is titled "Shop web"
    And its default model is still "Sonnet"

  @node
  Scenario: Deleting a project removes it from every sidebar
    When a client deletes the project "shop"
    Then "shop" is no longer listed for "laptop"
    And "/home/sam/shop" still exists on disk

  @node
  Scenario: Changing a project that does not exist fails
    When a client renames an unknown project
    Then the node answers "unknown project"

  @backlog @desktop @mobile @tui
  Scenario: Removing a project asks for confirmation and explains what is lost
    Given "shop" has 4 threads
    When the user asks to remove "shop"
    Then the user is told 4 threads and their conversation history will be cleared
    And the user is told the files on disk are kept

  @backlog @desktop @mobile @tui
  Scenario: Confirming removal clears the project and its drafts
    Given "shop" has an unsent draft
    When the user confirms removing "shop"
    Then "shop" is no longer listed for "laptop"
    And the draft for "shop" is gone

  @backlog @desktop @mobile @tui
  Scenario: Cancelling removal keeps the project
    When the user asks to remove "shop"
    And the user cancels
    Then "shop" is still listed for "laptop"

  @backlog @desktop
  Scenario: Removing the project the user is looking at returns home
    Given the user is looking at a thread in "shop"
    When the user confirms removing "shop" everywhere
    Then the user is taken home

  @backlog @desktop
  Scenario: Removing a registered folder from the folder explorer asks through project settings
    Given the folder explorer shows "/home/sam/shop"
    When the user removes "/home/sam/shop" from T3 Code
    Then the removal confirmation for "shop" on "laptop" opens

  Rule: Automatic pull at startup

    @node
    Scenario: A clean checkout behind its upstream is pulled when the node starts
      Given "shop" has automatic pull on
      And "shop" is a clean checkout of its default branch that is behind its upstream
      When the node starts
      Then "shop" is fast-forwarded to its upstream

    @node
    Scenario Outline: Checkouts that are not safe to pull are left alone
      Given "shop" has automatic pull on
      And "shop" <state>
      When the node starts
      Then "shop" is not pulled
      And the node starts normally

      Examples:
        | state                                  |
        | has uncommitted changes                |
        | is on a branch other than its default  |
        | has no upstream                        |
        | has commits its upstream does not have |

    @node
    Scenario: Automatic pull is off unless the project opts in
      Given "shop" is a clean checkout behind its upstream
      And automatic pull was never turned on for "shop"
      When the node starts
      Then "shop" is not pulled
