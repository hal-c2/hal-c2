# Sources:
#   docs/user/source-control.md (GitHub sharing across environments)
#   apps/web/src/components/settings/GitHubRoutingSettings.tsx
#   apps/web/src/connection/catalog.ts (setGitHubRoutingPermission)

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
