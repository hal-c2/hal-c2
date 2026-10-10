# Sources:
#   docs/user/source-control.md (providers, rescan)
#   apps/web/src/components/settings/SourceControlSettings.tsx
#   packages/contracts/src/rpc.ts (server.discoverSourceControl)
#   apps/server-ex/lib/hal_c2/source_control.ex (discover)
#   apps/server-ex/lib/hal_c2/background_policy.ex (automaticGitFetchInterval)
#   apps/tui/src/host/sections/sourceControl.ts (the terminal client's tools page)

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

  @backlog @desktop
  Scenario: Source control tools need a connected environment
    Given no environment is connected
    When the user opens Settings, Source Control
    Then the user is told to connect an environment to inspect its version control tools and hosting integrations

  @backlog @desktop
  Scenario: Several environments show one machine's tools at a time
    Given the user is editing settings across "Laptop" and "Build box"
    When the panel loads
    Then the tools of "Laptop" are listed
    And the version control section is named after "Laptop"

  @backlog @desktop
  Scenario: The first scan shows placeholders and can be rescanned only once it ends
    When the panel is still running its first scan
    Then placeholders stand in for the tools
    And rescanning is not possible until the scan ends

  @backlog @desktop
  Scenario Outline: A hosting tool says why it cannot be used yet
    Given the hosting tool "GitLab" <state>
    When the panel loads
    Then its line reads "<text>"

    Examples:
      | state                                                    | text                                                                       |
      | is installed and signed in as "tanya"                    | Authenticated as tanya                                                      |
      | is installed but not signed in                           | GitLab is not authenticated on this server, with how to sign in on the host |
      | is available without a command line tool to sign in with | Available, with its install hint                                           |
      | is installed but its sign-in could not be checked        | Could not verify GitLab, with the reason or the install hint               |
      | is not on this server                                    | Not available on this server, with its install hint                         |

  @backlog @desktop
  Scenario: A tool's availability is shown, not changed
    When the user looks at a tool's availability
    Then it shows on only when the tool is available and, for a hosting tool, signed in
    And the user cannot change it from the panel

  @backlog @desktop
  Scenario: Git's details open from its row or from a search for the fetch interval
    Given the panel lists Git
    When the user searches settings for the automatic fetch interval
    Then Git's details open with the interval in view
    And no other tool offers details

  @backlog @desktop
  Scenario Outline: A fetch interval is kept as whole seconds from zero
    When the user enters <typed> as the automatic Git fetch interval
    Then it is kept as <kept> seconds

    Examples:
      | typed | kept |
      | 45    | 45   |
      | 12.6  | 13   |
      | -5    | 0    |
      | empty | 0    |

  @backlog @desktop
  Scenario: A custom fetch interval makes the background profile advanced
    Given the background activity profile is "Balanced"
    When the user sets a fetch interval that is not the profile's
    Then General settings show the background activity profile as advanced
    And the shared background activity policy still decides whether a fetch may run when the timer fires

  @backlog @desktop
  Scenario: Scanning can be retried from the empty state
    Given nothing was detected on the environment
    When the user chooses to scan from the empty state
    Then the environment is scanned again
    And scanning cannot be started twice while it runs

  @backlog @desktop
  Scenario: Hosting tools are listed alone when there is no version control tool
    Given the environment reports hosting tools but no version control tool
    When the panel loads
    Then the hosting tools are listed
    And the rescan control is on that list
