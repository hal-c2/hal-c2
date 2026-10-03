# Sources:
#   docs/user/source-control.md (providers, rescan)
#   apps/web/src/components/settings/SourceControlSettings.tsx
#   packages/contracts/src/rpc.ts (server.discoverSourceControl)
#   apps/server-ex/lib/hal_c2/source_control.ex (discover)
#   apps/server-ex/lib/hal_c2/background_policy.ex (automaticGitFetchInterval)

Feature: Source Control settings
  The Source Control panel shows which version control and hosting tools the server
  environment has, whether each is signed in, and how often Git fetches in the background.
  What the tools do lives in source-control/.

  Background:
    Given the user is connected to an environment and opens Settings, Source Control

  @desktop @mobile @backlog-mobile
  Scenario: The panel lists each tool with its state
    When the panel loads
    Then each version control and hosting tool is listed as available, missing or status unknown
    And each available tool shows its version

  @desktop @mobile @backlog-mobile
  Scenario: Revealing a signed-in account
    Given the GitHub CLI is signed in as "octocat"
    And GitHub reads "Authenticated" without the account name
    When the user reveals the account
    Then the account "octocat" is shown

  @desktop @mobile @backlog-mobile
  Scenario: Hiding a revealed account again
    Given the user revealed the GitHub account
    When the user hides it
    Then the account name is hidden again

  @desktop @mobile @backlog-mobile
  Scenario: A tool that is not signed in says so
    Given the GitHub CLI is installed but not signed in
    When the panel loads
    Then GitHub reads "Not authenticated" with how to sign in

  @desktop @mobile @backlog-mobile
  Scenario: A missing tool shows how to install it
    Given the GitLab CLI is not installed
    When the panel loads
    Then GitLab is shown as missing with its install instructions

  @desktop @mobile @backlog-mobile
  Scenario: Rescanning after installing a tool
    Given the GitHub CLI was missing when the panel loaded
    And the user has since installed and signed in to it
    When the user rescans Git and hosting integrations
    Then GitHub reads "Authenticated"

  @desktop @mobile @backlog-mobile
  Scenario: Nothing detected yet
    Given the environment has no version control or hosting tools
    When the panel loads
    Then the user is told nothing was detected yet and to install Git on the server and rescan

  @desktop @mobile @backlog-mobile
  Scenario: The environment could not be scanned
    Given the scan fails
    When the panel loads
    Then the user is told "Could not scan the server environment"

  @desktop @mobile @backlog-mobile
  Scenario: A host that is not supported yet is marked coming soon
    When the panel loads
    Then hosts HAL-C2 cannot use yet are marked "Coming Soon"

  @desktop @mobile @backlog-mobile
  Scenario: Changing the automatic fetch interval
    When the user sets the automatic Git fetch interval to 60 seconds
    Then Git fetches every 60 seconds while a thread is on screen

  @desktop @mobile @backlog-mobile
  Scenario: Resetting the fetch interval to the background profile
    Given the user set the automatic Git fetch interval to 60 seconds
    When the user resets the fetch interval
    Then the interval follows the background activity profile again

  @desktop @mobile @backlog-mobile
  Scenario: A fetch interval of zero turns background fetching off
    When the user sets the automatic Git fetch interval to 0 seconds
    Then Git never fetches in the background

  @tui
  Scenario: Seeing source control tools from the terminal client
    When the user opens source control settings in the terminal client
    Then each tool is shown as authenticated, unavailable or needing setup
