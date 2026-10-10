# Sources:
#   docs/user/source-control.md (GitHub sharing across environments)
#   packages/contracts/src/pullRequest.ts (PullRequestRouting, PullRequestRoutingIdentity, expectedAccountId, allowStale)
#   packages/contracts/src/rpc.ts (pullRequests.routing, pullRequests.routingIdentity)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (routing, routing_identity, verified)
#   apps/web/src/components/settings/GitHubRoutingSettings.tsx
#   apps/web/src/connection/catalog.ts (githubRoutingPermissions)
#   apps/server/src/pullRequest/PullRequestService.ts (requireProject, routing, withRoutingCredential)
#   apps/server/src/sourceControl/GitHubCli.ts (targetsVerifiedHost, executeRaw)
#   packages/client-runtime/src/state/pullRequestRouting.ts (which environment answers, fallback, refresh after an action)

Feature: Sharing GitHub access between environments
  A client connected to several environments can read or act on pull requests through
  whichever environment is signed in to GitHub, once the user allows it for that environment.

  Background:
    Given the user is connected to the local environment and the remote environment "build-box"

  @mc
  Scenario: An environment names the GitHub account it acts as
    Given "build-box" has the GitHub CLI signed in as "octocat"
    When a client asks "build-box" who it is on "github.com"
    Then "build-box" answers with the account id and login of "octocat"

  @mc
  Scenario: An environment without a GitHub project cannot route
    Given "build-box" has no project on "github.com"
    When a client asks "build-box" who it is on "github.com"
    Then the answer is that the provider is unsupported there

  @mc
  Scenario: An operation checks it acts as the expected account
    Given the client expects "build-box" to act as the account of "octocat"
    And "build-box" is now signed in as "hubot"
    When the client merges a pull request through "build-box"
    Then the merge is refused with "The GitHub account could not be verified before starting the operation."

  @mc
  Scenario: The signed-in account is believed for ten minutes
    Given "build-box" verified its GitHub account 5 minutes ago
    When a client asks "build-box" who it is on "github.com"
    Then the answer comes without asking GitHub again

  @backlog @desktop @mobile
  Scenario: Sharing is off until the user allows it
    Given the user never changed GitHub sharing for "build-box"
    When the local environment cannot read "acme/shop"
    Then pull requests of "acme/shop" are not read through "build-box"

  @backlog @desktop @mobile
  Scenario: Reading pull requests through another environment
    Given the user allowed "build-box" to read pull requests
    And only "build-box" is signed in to GitHub
    When the user opens a pull request of "acme/shop"
    Then it is read through "build-box"
    But merging it is not offered

  @backlog @desktop @mobile
  Scenario: Acting on pull requests through another environment
    Given the user allowed "build-box" to read and act on pull requests
    When the user merges a pull request of "acme/shop"
    Then the merge runs through "build-box"

  @backlog @desktop @mobile
  Scenario: The local environment is preferred
    Given both environments may act on pull requests and both are signed in
    When the user opens a pull request
    Then it is read through the local environment

  @backlog @desktop @mobile
  Scenario: Verified credentials survive a short outage
    Given "build-box" verified its GitHub account 5 minutes ago and then lost GitHub
    When the user opens a pull request
    Then "build-box" is still used for routing

  @backlog @desktop @mobile
  Scenario: An action with an uncertain result is never retried elsewhere
    Given a merge through "build-box" timed out without an answer
    When the user looks at the result
    Then the merge is not retried through the local environment

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (routingAllowed)
  @backlog @desktop @mobile
  Scenario Outline: Sharing needs both environments to allow it
    Given the local environment is set to "<local>" and "build-box" is set to "<remote>"
    When the user <does> a pull request of "acme/shop" that the local environment cannot reach
    Then it <result> through "build-box"

    Examples:
      | local        | remote       | does   | result       |
      | Read PRs     | Read PRs     | reads  | is read      |
      | Off          | Read PRs     | reads  | is not read  |
      | Read PRs     | Read and act | merges | is not merged |
      | Read and act | Read and act | merges | is merged    |

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (visit, readTimeout)
  @backlog @desktop @mobile
  Scenario: A read that another environment cannot answer is tried elsewhere
    Given both environments may read pull requests and both are signed in
    And "build-box" does not answer within 30 seconds
    When the user opens a pull request of "acme/shop"
    Then it is read through the environment the user opened it from instead

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (alternate identity check)
  @backlog @desktop @mobile
  Scenario: An environment signed in as another GitHub account is not used
    Given "build-box" may read pull requests and is signed in as "hubot"
    And the pull request of "acme/shop" was read for the account "octocat"
    When the user opens it again
    Then "build-box" is skipped
    And it is read through an environment signed in as "octocat"

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (pullRequestChecks capability)
  @backlog @desktop @mobile
  Scenario: Checks are only read through environments that can read them
    Given "build-box" may read pull requests and runs an older server that cannot read checks
    When the user looks at the checks of a pull request of "acme/shop"
    Then they are not read through "build-box"

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (finish, invalidateTarget)
  @backlog @desktop @mobile
  Scenario: Acting on a pull request refreshes it in the environments that read it
    Given the user read a pull request of "acme/shop" through "build-box"
    When the user comments on it from the local environment
    Then the next read of that pull request through "build-box" asks GitHub again

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (Effect.map projectId)
  @backlog @desktop @mobile
  Scenario: A pull request read through another environment belongs to the project it was opened from
    Given the user opens a pull request from the project "shop" of the local environment
    When it is read through "build-box"
    Then it is shown under the project "shop" of the local environment

  # Legacy: packages/client-runtime/src/state/pullRequestRouting.ts (allowStale)
  @backlog @desktop @mobile
  Scenario: A pull request that could not be read fresh from anywhere shows the last copy
    Given the user read the summary of a pull request a minute ago
    And no environment can read it fresh now
    When the user opens it
    Then the last copy is shown

  @backlog @desktop @mobile
  Scenario: Changing an environment's address clears its sharing
    Given the user allowed "build-box" to read and act on pull requests
    When the user changes the address of "build-box"
    Then GitHub sharing for "build-box" is off again

  @backlog @mc
  Scenario: A pull request of another repository is refused when only the project's own is meant
    Given "build-box" has the project "shop" for "acme/shop" on "github.com"
    When a client asks for pull request 7 of "acme/other" for "shop" without naming a host
    Then it is refused with "The change request does not belong to the selected project."
    And the host is not asked anything

  @backlog @mc
  Scenario: A pull request on a host no project of the environment reads is unsupported
    Given "build-box" has no project on "git.example.test"
    When a client asks for pull request 7 of "team/app" on "git.example.test"
    Then the answer is that the provider is unsupported there

  @backlog @mc
  Scenario: An account that cannot be told is refused
    Given the GitHub CLI of "build-box" answers without a login or an account id
    When a client asks "build-box" who it is on "github.com"
    Then it is refused with "The signed-in account could not be verified."

  @backlog @mc
  Scenario: An operation for another host than its project's is not run as the expected account
    Given the client expects "build-box" to act as the account of "octocat"
    When the client merges a pull request on "git.example.test" through "build-box"
    Then the merge is refused with "The GitHub account could not be verified before starting the operation."
    And nothing is merged

  # Legacy: apps/server/src/sourceControl/GitHubCli.ts (targetsVerifiedHost, executeRaw)
  # Legacy: apps/server/src/sourceControl/GitHubCli.test.ts (refuses other or implicit hosts before exposing a scoped credential to gh)
  @backlog @mc
  Scenario Outline: A verified credential is only handed to a command that names its own host
    Given "build-box" verified its account on "github.com"
    When a GitHub command is run for that account that <command>
    Then the command is refused before the GitHub CLI is started
    And the credential appears nowhere in the error

    Examples:
      | command                                              |
      | asks another host by name                            |
      | names a repository on another host                   |
      | fetches an address on another host                   |
      | names no host at all                                 |

  # Legacy: apps/server/src/sourceControl/GitHubCli.ts (executeRaw env)
  # Legacy: apps/server/src/sourceControl/GitHubCli.test.ts (pins concurrent cached commands to their own verified credentials)
  @backlog @mc
  Scenario: Commands for two verified accounts at once each run as their own account
    Given "build-box" verified one account on "github.com" and another on a self-hosted GitHub
    When both accounts' reads run at the same moment
    Then each read runs with only its own account's credential
    And neither account's credential is overridden by one set in the environment

  @backlog @mc
  Scenario: A list that cannot read the environment's projects says so
    Given "build-box" cannot read its list of projects
    When a client lists pull requests through "build-box"
    Then it is refused with "The project list could not be read."
