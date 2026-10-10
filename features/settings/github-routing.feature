# Sources:
#   docs/user/source-control.md (GitHub sharing across environments)
#   apps/web/src/components/settings/GitHubRoutingSettings.tsx
#   apps/web/src/components/settings/GitHubRoutingSettings.test.ts (closed summary groups by permission)
#   apps/web/src/connection/catalog.ts (setGitHubRoutingPermission)
#   packages/client-runtime/src/connection/githubRoutingPermissions.ts (permission keyed on the saved endpoint)

@backlog @desktop @mobile
Feature: GitHub routing settings
  Under the environments list, a GitHub routing section lets the user choose, per
  environment, whether other environments may read or act on pull requests through it.
  The routing itself lives in source-control/pull-request-routing.feature.

  Background:
    Given the user is connected to the local environment and the remote environment "build-box"
    And the user opens the environments settings

  Scenario: The section appears only with more than one environment
    Given the user is connected to only one environment
    When the user opens the environments settings
    Then no GitHub routing section is shown

  Scenario: Every environment starts off
    When the user opens the GitHub routing section
    Then "build-box" and the local environment are both set to "Off"
    And the section's summary reads "Off"

  Scenario Outline: Choosing what an environment may do
    When the user sets "build-box" to "<permission>"
    Then the section's summary reads "build-box <summary>"

    Examples:
      | permission    | summary       |
      | Read PRs      | read PRs      |
      | Read and act  | read and act  |

  Scenario: Turning sharing off again
    Given "build-box" is set to "Read and act"
    When the user sets "build-box" to "Off"
    Then pull requests are no longer read or changed through "build-box"

  Scenario: A permission that could not be saved
    Given saving the permission fails
    When the user sets "build-box" to "Read PRs"
    Then the user is told "Could not save GitHub routing permission"
    And "build-box" still reads "Off"

  Scenario: An environment without a stable address cannot be shared
    Given "build-box" has no connection address to key its permission on
    When the user opens the GitHub routing section
    Then the permission for "build-box" cannot be changed

  Scenario: Removing an environment clears its permission
    Given "build-box" is set to "Read and act"
    When the user removes "build-box" and adds it again
    Then "build-box" reads "Off"

  @backlog @desktop @mobile
  Scenario: The closed section summarises who shares what
    Given "laptop" and "build-box" are set to "Read and act"
    And "server" is set to "Read PRs"
    When the user looks at the GitHub routing section while it is closed
    Then the summary reads "laptop, build-box read and act · server read PRs"

  @backlog @desktop @mobile
  Scenario: The section warns about trust before the choices
    When the user opens the GitHub routing section
    Then the user is told that trusted machines read PR data through each other's GitHub access
    And that both machines must be enabled
    And that read and act may use broader permissions than the machine that owns them
    And that the choice applies only to this device

  @backlog @desktop @mobile
  Scenario: Permissions cannot be changed until saved ones are loaded or while one saves
    Given the saved permissions are still loading
    Then no environment's GitHub routing can be changed
    When the user is saving a permission for "build-box"
    Then the other environments' GitHub routing cannot be changed until it is saved

  @backlog @desktop @mobile
  Scenario: A switched-off environment is not listed for GitHub routing
    Given "build-box" is switched off
    When the user opens the GitHub routing section
    Then "build-box" is not listed
    And with only one environment left switched on the section is not shown
