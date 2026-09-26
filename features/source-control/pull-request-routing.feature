# Sources:
#   docs/user/source-control.md (GitHub sharing across environments)
#   packages/contracts/src/pullRequest.ts (PullRequestRouting, PullRequestRoutingIdentity, expectedAccountId, allowStale)
#   packages/contracts/src/rpc.ts (pullRequests.routing, pullRequests.routingIdentity)
#   apps/server-ex/lib/t3/pull_requests.ex (routing, routing_identity, verified)
#   apps/web/src/components/settings/GitHubRoutingSettings.tsx
#   apps/web/src/connection/catalog.ts (githubRoutingPermissions)

Feature: Sharing GitHub access between environments
  A client connected to several environments can read or act on pull requests through
  whichever environment is signed in to GitHub, once the user allows it for that environment.

  Background:
    Given the user is connected to the local environment and the remote environment "build-box"

  @node
  Scenario: An environment names the GitHub account it acts as
    Given "build-box" has the GitHub CLI signed in as "octocat"
    When a client asks "build-box" who it is on "github.com"
    Then "build-box" answers with the account id and login of "octocat"

  @node
  Scenario: An environment without a GitHub project cannot route
    Given "build-box" has no project on "github.com"
    When a client asks "build-box" who it is on "github.com"
    Then the answer is that the provider is unsupported there

  @node
  Scenario: An operation checks it acts as the expected account
    Given the client expects "build-box" to act as the account of "octocat"
    And "build-box" is now signed in as "hubot"
    When the client merges a pull request through "build-box"
    Then the merge is refused with "The GitHub account could not be verified before starting the operation."

  @node
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

  @backlog @desktop @mobile
  Scenario: Changing an environment's address clears its sharing
    Given the user allowed "build-box" to read and act on pull requests
    When the user changes the address of "build-box"
    Then GitHub sharing for "build-box" is off again
