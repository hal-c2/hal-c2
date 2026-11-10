# Sources:
#   https://github.com/pingdotgg/t3code/pull/21606
#   https://github.com/pingdotgg/t3code/pull/27102
#   https://github.com/pingdotgg/t3code/pull/13253
#   https://github.com/pingdotgg/t3code/pull/17901
#   https://github.com/pingdotgg/t3code/pull/16322
#   https://github.com/pingdotgg/t3code/pull/14103
#   https://github.com/pingdotgg/t3code/pull/22495
#   https://github.com/pingdotgg/t3code/pull/27746
#   https://github.com/pingdotgg/t3code/pull/22778
#   https://github.com/pingdotgg/t3code/pull/26245
#   https://github.com/pingdotgg/t3code/pull/29554
#   https://github.com/pingdotgg/t3code/pull/27840
#   https://github.com/pingdotgg/t3code/pull/31646
#   https://github.com/pingdotgg/t3code/pull/27756
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

  @desktop @mobile @backlog-mobile @priority-low
  Scenario: Revealing a signed-in account
    Given the GitHub CLI is signed in as "octocat"
    And GitHub reads "Authenticated" without the account name
    When the user reveals the account
    Then the account "octocat" is shown

  @desktop @mobile @backlog-mobile @priority-low
  Scenario: Hiding a revealed account again
    Given the user revealed the GitHub account
    When the user hides it
    Then the account name is hidden again

  @desktop @mobile @backlog-mobile
  Scenario: A tool that is not signed in says so
    Given the GitHub CLI is installed but not signed in
    When the panel loads
    Then GitHub reads "Not authenticated" with how to sign in

  # Upstream #22778: hosting tools the user never set up showed warning marks, as if broken.
  @backlog @desktop @priority-low
  Scenario: A hosting tool that is not set up is shown as unused, not as a problem
    Given the GitLab CLI is not installed and the GitHub CLI is installed but not signed in
    When the panel loads
    Then neither is marked as a warning
    And a tool that is installed and signed in is marked ready

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

  @desktop @mobile @backlog-mobile @priority-low
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

  # Upstream #13253: a zero fetch interval also stops the fetch and pull on window focus.
  @backlog @mc @desktop
  Scenario: With fetching off, coming back to the window neither fetches nor pulls
    Given the automatic Git fetch interval is 0 seconds
    And the default branch is clean and was behind its remote when last fetched
    When the user comes back to the window
    Then Git does not fetch and the branch is not pulled
    And the branch's local status still refreshes

  @tui
  Scenario: Seeing source control tools from the terminal client
    When the user opens source control settings in the terminal client
    Then each tool is shown as authenticated, unavailable or needing setup

  @backlog @desktop
  Scenario: Source control tools need a connected environment
    Given no environment is connected
    When the user opens Settings, Source Control
    Then the user is told to connect an environment to inspect its version control tools and hosting integrations

  @backlog @desktop @priority-low
  Scenario: Several environments show one machine's tools at a time
    Given the user is editing settings across "Laptop" and "Build box"
    When the panel loads
    Then the tools of "Laptop" are listed
    And the version control section is named after "Laptop"

  @backlog @desktop @priority-low
  Scenario: The first scan shows placeholders and can be rescanned only once it ends
    When the panel is still running its first scan
    Then placeholders stand in for the tools
    And rescanning is not possible until the scan ends

  # Upstream #27102: the scan waited on the slowest host; Bitbucket's account check took over
  # ten seconds even with no Bitbucket credential.
  @backlog @mc @priority-high
  Scenario: A host that does not answer does not hold up the scan
    Given Bitbucket has a saved token but its server never answers
    When the user rescans Git and hosting integrations
    Then the scan finishes within 5 seconds
    And Bitbucket's sign-in is shown as unknown after 3 seconds
    And the other tools are listed as usual

  # Upstream #27102
  @backlog @mc
  Scenario: A host with no credential is not contacted by the scan
    Given no Bitbucket credential is saved
    When the user rescans Git and hosting integrations
    Then no request is made to Bitbucket
    And Bitbucket is shown as not signed in

  @backlog @desktop @priority-low
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

  # Upstream #27840: glab checks only its default host, so a signed-out default hid another
  # signed-in host and turned off GitLab publish and add project.
  @backlog @mc
  Scenario: GitLab signed in on another host counts as signed in
    Given glab's default host is signed out
    And another host glab knows is signed in
    When the panel loads
    Then GitLab is authenticated
    And GitLab publish and add project are available

  # Upstream #21606: on an Apple Silicon Mac without Rosetta, an Intel-only gh read as not
  # installed and the user was told to install what they had.
  @backlog @mc @desktop @priority-low
  Scenario: A tool built for another processor says which file to replace
    Given the first "gh" on the server's path is "/usr/local/bin/gh", built only for Intel
    And the server is an Apple Silicon Mac that cannot run it
    When the panel loads
    Then GitHub is not available
    And its hint says "/usr/local/bin/gh" is built for another processor and should be removed or replaced
    And the same holds for a "git" or "jj" built for another processor

  @backlog @desktop @priority-low
  Scenario: A tool's availability is shown, not changed
    When the user looks at a tool's availability
    Then it shows on only when the tool is available and, for a hosting tool, signed in
    And the user cannot change it from the panel

  @backlog @desktop @priority-low
  Scenario: Git's details open from its row or from a search for the fetch interval
    Given the panel lists Git
    When the user searches settings for the automatic fetch interval
    Then Git's details open with the interval in view
    And no other tool offers details

  @backlog @desktop @priority-low
  Scenario Outline: A fetch interval is kept as whole seconds from zero
    When the user enters <typed> as the automatic Git fetch interval
    Then it is kept as <kept> seconds

    Examples:
      | typed | kept |
      | 45    | 45   |
      | 12.6  | 13   |
      | -5    | 0    |
      | empty | 0    |

  @backlog @desktop @priority-low
  Scenario: A custom fetch interval makes the background profile advanced
    Given the background activity profile is "Balanced"
    When the user sets a fetch interval that is not the profile's
    Then General settings show the background activity profile as advanced
    And the shared background activity policy still decides whether a fetch may run when the timer fires

  @backlog @desktop @priority-low
  Scenario: Scanning can be retried from the empty state
    Given nothing was detected on the environment
    When the user chooses to scan from the empty state
    Then the environment is scanned again
    And scanning cannot be started twice while it runs

  @backlog @desktop @priority-low
  Scenario: Hosting tools are listed alone when there is no version control tool
    Given the environment reports hosting tools but no version control tool
    When the panel loads
    Then the hosting tools are listed
    And the rescan control is on that list

  # Bitbucket credentials entered in Settings instead of the server's environment variables.
  # The tokens live in the environment's secret store and never reach a client.
  # Upstream #14103: Bitbucket credentials are saved from Source Control settings
  @backlog @desktop @mobile
  Scenario: A Bitbucket access token is saved from Source Control settings
    Given Bitbucket is not configured on the environment
    When the user opens Bitbucket and saves an access token
    Then Bitbucket is configured on the environment without a restart
    And the token is shown as a saved, masked value

  # Upstream #14103: Bitbucket credentials are saved from Source Control settings
  @backlog @desktop @mobile
  Scenario: Saving a Bitbucket sign-in method clears the other one
    Given Bitbucket has a saved API token and an Atlassian account email
    When the user saves an access token
    Then the API token and the email are cleared

  # Upstream #14103: Bitbucket credentials are saved from Source Control settings
  @backlog @desktop @mobile
  Scenario: Removing Bitbucket credentials leaves Bitbucket unconfigured
    Given Bitbucket has a saved access token
    When the user removes the Bitbucket credentials
    Then Bitbucket is not configured on the environment

  # Upstream #14103: Bitbucket credentials are saved from Source Control settings
  @backlog @mc @priority-high
  Scenario: A saved Bitbucket token stays out of the settings file and every client payload
    Given the user saved a Bitbucket API token on the environment
    When a client reads the server settings
    Then the client learns only that a token is set
    And the token is not written to the settings file

  # Upstream #27746: Bitbucket and GitCafe credentials can name a secret in a secret provider.
  @backlog @shared @mc
  Scenario Outline: A <host> credential can be a reference to a secret provider
    When the user sets the <host> <credential> to the reference "op://Work/<host>/token"
    Then the reference is saved and shown as written, not copied into the secret store
    And the MC reads the secret through the reference when it talks to <host>

    Examples:
      | host      | credential   |
      | Bitbucket | access token |
      | Bitbucket | API token    |
      | GitCafe   | token        |

  # Upstream #27746: an unreadable saved reference quietly used GH_TOKEN, gh, cafe or the
  # Bitbucket environment login instead, so pull request actions ran as another account.
  # Upstream #31646: replaced that fallback with a failure.
  @backlog @mc @priority-high
  Scenario Outline: A <host> credential that cannot be read fails instead of using another login
    Given the <host> token is a reference to "Work", which cannot be read
    And a <host> login is available from the environment or the host's command-line tool
    When the MC talks to <host>
    Then it fails with an error naming the secret provider "Work"
    And the other login is not used
    And the <host> status in Settings shows that error
    And startup and the other hosts are unaffected

    Examples:
      | host      |
      | GitHub    |
      | GitCafe   |
      | Bitbucket |

  # Upstream #31646: only a field left empty uses the environment or command-line login.
  @backlog @mc
  Scenario: An empty source control credential uses the environment's login
    Given no GitHub token is saved in Settings
    And "GH_TOKEN" is set for the MC
    When the MC talks to GitHub
    Then it uses "GH_TOKEN"

  # Upstream #29554: a client sending the whole token map replaced it, so saving one host's token
  # wiped every other host's token and secret reference.
  @backlog @mc @priority-high
  Scenario: Saving one host's token keeps the other hosts' saved tokens
    Given tokens are saved for "github.com" and "github.example.com"
    When a client saves a new token for "github.com" alone
    Then the token for "github.example.com" is still saved
    And removing the token for "github.com" leaves "github.example.com" saved too

  # Upstream #27756: a host's token had to be pasted in; teams keeping it in 1Password could not
  # read it from there.
  @backlog @mc @shared
  Scenario: A host's token can come from a secret provider
    Given the 1Password secret provider "Work" is set up
    When the user points the token for "github.com" at "op://vault/github/token" in "Work"
    Then the MC reads the token from "Work" when it talks to GitHub
    And the settings show the reference as written
    And the token for "github.example.com" is still saved as it was

  # Upstream #27756: an unreadable per-host token reference counts as no saved token, so the
  # environment fallback applies.
  @backlog @mc @priority-low
  Scenario: A host token reference that cannot be read counts as no token
    Given the token for "github.com" points at a secret "Work" cannot read
    And "GH_TOKEN" is set for the MC
    When the MC talks to GitHub
    Then it uses "GH_TOKEN"

  # Upstream #16322: choose the GitHub account per host
  @backlog @shared
  Scenario: The user chooses which GitHub account an MC uses for each host
    Given the user is signed in to GitHub as "work" and "personal" on one host
    When the user picks "work" for that host
    Then the MC uses "work" for that host's requests from then on
    And a host turned off in settings refuses its requests and says where to turn it on

  # Upstream #16322: a GitHub token is saved in Settings
  @backlog @mc
  Scenario: GitHub works from a saved token without the GitHub CLI
    Given the user saved a GitHub token
    When the MC talks to GitHub
    Then it uses the token and does not need the GitHub CLI

  # Upstream #26245: GitHub requests shared the user's personal API limit, so busy days stalled
  # pull request status. Signing in through an app owned by an organisation gets a higher limit.
  @backlog @mc @shared
  Scenario: Signing in to GitHub through the app shows a code to approve in a browser
    Given the MC is not signed in to GitHub through the app
    When the user chooses "Sign in with GitHub" in Source Control settings
    Then the client shows a code and where to enter it
    When the user approves the code in a browser
    Then GitHub shows as signed in through the app, and signing out falls back to the other credentials

  # Upstream #26245: the credential order, and a retry with the user's own for a repository the
  # app is not installed on.
  @backlog @mc
  Scenario Outline: A GitHub request uses the app sign-in after a saved token and before the others
    Given the MC is signed in to GitHub through the app and <other> is available
    When the MC asks GitHub about "acme/shop"
    Then <outcome>

    Examples:
      | other                                                      | outcome                                       |
      | a saved GitHub token                                       | it uses the saved token                       |
      | the GitHub CLI's login                                     | it uses the app sign-in                       |
      | the GitHub CLI's login, and the app cannot see "acme/shop" | it asks once more with the GitHub CLI's login |

  # Upstream #26245: a refresh token GitHub rejects signs the app out.
  @backlog @mc
  Scenario: An app sign-in GitHub no longer accepts signs out
    Given the MC is signed in to GitHub through the app
    When GitHub rejects the sign-in's refresh token
    Then the MC is signed out of the app and uses the environment token or the GitHub CLI's login

  # Upstream #17901: host settings live on each host definition, with a GitCafe token
  @backlog @mc @shared
  Scenario: A GitCafe token is saved from Source Control settings
    Given GitCafe is not signed in through its CLI or environment
    When the user saves a GitCafe token
    Then GitCafe works at once, using the saved token before any from the environment or the CLI
    And the token is only sent to git.cafe, never to its staging host

  # Upstream #22495: creating a GitCafe repository or pull request still needed the cafe CLI
  # when a token covered everything else.
  @backlog @mc @priority-low
  Scenario: A GitCafe token alone creates repositories and pull requests
    Given the user saved a GitCafe token and the cafe CLI is not installed
    When the user publishes a project as a new GitCafe repository and opens a pull request from a fork
    Then the repository and the pull request are created

  # Upstream #17901: host settings live on each host definition, with a GitCafe token
  @backlog @mc @shared
  Scenario: A host's saved secret is never shown back
    Given the user saved a secret for a source control host
    When the user opens that host's settings on any client
    Then the field says a secret is saved without showing it

  # Upstream #17901: host settings live on each host definition, with a GitCafe token
  @backlog @mc @shared @priority-low
  Scenario: Removing a host's settings clears them
    Given a source control host has saved settings and a token
    When the user removes that host's settings
    Then the host's settings and token are gone and the host falls back to its environment or CLI sign-in

  # Upstream #17901: host settings live on each host definition, with a GitCafe token
  @backlog @mc @priority-low
  Scenario: Settings of a host this MC does not know are kept
    Given the settings file holds settings for a source control host this MC does not ship
    When the MC saves other settings
    Then that host's settings are still in the file
