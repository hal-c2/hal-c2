# Sources:
#   docs/user/source-control.md (Linked pull requests)
#   packages/contracts/src/git.ts (GitResolvePullRequestInput, GitPreparePullRequestThreadInput, GitPreparePullRequestThreadResult)
#   packages/contracts/src/rpc.ts (git.resolvePullRequest, git.preparePullRequestThread, pullRequests.linkedThreads, pullRequests.preview)
#   packages/contracts/src/orchestrationV2.ts (thread.pull-request.link, thread.pull-request.unlink, thread.pull-request-link.sync, thread.pull-request-synced)
#   apps/server-ex/lib/hal_c2/pull_requests/checkout.ex
#   apps/server-ex/lib/hal_c2/pull_requests/discovery.ex
#   apps/server-ex/lib/hal_c2/pull_requests/sync.ex
#   apps/server-ex/lib/hal_c2/mcp/tools/pull_requests.ex (link_pull_request, unlink_pull_request, list_thread_pull_requests)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.pull-request.link)
#   apps/web/src/components/PullRequestThreadDialog.tsx
#   apps/web/src/components/PullRequestContextDetails.tsx
#   apps/web/src/components/pullRequest/LinkPullRequestDialog.tsx
#   apps/web/src/components/pullRequest/PullRequestLinkPreview.tsx
#   apps/web/src/components/pullRequest/pullRequestLinkContextMenu.ts
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (open pull request)
#   apps/tui/src/features.backlog.test.ts (pull request checkout)

Feature: Threads that work on or link pull requests
  A thread can start from a pull request, checked out locally or in its own worktree,
  and any thread can link the pull requests it relates to and keep them current.

  Background:
    Given a connected environment with the GitHub project "acme/shop"

  @node
  Scenario Outline: A pull request can be named in several ways
    When the user asks to work on the pull request <reference>
    Then pull request 42 of "acme/shop" is resolved with its title, branches and state

    Examples:
      | reference                                 |
      | 42                                        |
      | #42                                       |
      | https://github.com/acme/shop/pull/42      |

  @node
  Scenario: A pull request that does not exist
    When the user asks to work on the pull request 9999
    Then the user is told the pull request was not found

  @node
  Scenario: Working on a pull request in the local checkout
    When the user starts a thread on pull request 42 in the local checkout
    Then the project's checkout switches to the pull request's branch
    And the new thread is linked to pull request 42

  @node
  Scenario: Working on a pull request in its own worktree
    When the user starts a thread on pull request 42 in a new worktree
    Then the pull request's head is fetched into a worktree of its own
    And the new thread works in that worktree

  @node
  Scenario: A pull request from a fork gets a branch of its own
    Given pull request 42 comes from the fork branch "tax"
    When the user starts a thread on pull request 42 in a new worktree
    Then the worktree is on the branch "hal-c2/pr-42/tax" with no upstream

  @node
  Scenario: An existing worktree for the pull request is reused
    Given a worktree for pull request 42 exists with local commits
    When the user starts a thread on pull request 42 in a new worktree
    Then the existing worktree is reused
    And the user is told the checkout is not on the pull request's head

  @node
  Scenario: A pull request branch already in the main checkout cannot get a worktree
    Given the main checkout is on pull request 42's branch
    When the user starts a thread on pull request 42 in a new worktree
    Then the user is told to use the local checkout or switch the main checkout off that branch

  @node
  Scenario: Pull request worktrees do not run the setup script
    Given "acme/shop" has a setup script for new worktrees
    When the user starts a thread on pull request 42 in a new worktree
    Then the setup script does not run

  @backlog @desktop @mobile @tui
  Scenario: Starting a pull request thread from a pasted link
    When the user pastes "https://github.com/acme/shop/pull/42" to start a pull request thread
    Then the user sees the pull request's title and branches before choosing local or worktree

  @node
  Scenario: Linking a pull request to a thread
    Given the thread "Tax work" has no linked pull request
    When the user links pull request 42 to "Tax work"
    Then "Tax work" lists pull request 42 with its current state

  @node
  Scenario: Unlinking a pull request from a thread
    Given pull request 42 is linked to "Tax work"
    When the user unlinks pull request 42
    Then "Tax work" no longer lists pull request 42

  @node
  Scenario: A thread links several pull requests across repositories
    When the user links "acme/shop" pull request 42 and "acme/api" pull request 7 to "Tax work"
    Then "Tax work" lists both pull requests

  @node
  Scenario: The agent links the pull request it opened
    When the agent in "Tax work" opens pull request 43 and links it with its tool
    Then "Tax work" lists pull request 43

  @node
  Scenario: Creating a pull request from a thread links it
    When the user creates a pull request from "Tax work"
    Then "Tax work" lists the new pull request

  @node
  Scenario: The branch's pull request is discovered on its own
    Given "Tax work" is on the branch "feature/tax" with no linked pull request
    When someone opens a pull request for "feature/tax" on GitHub
    Then within a minute "Tax work" shows that pull request as its branch's

  @node
  Scenario: A merged link moves to the branch's open pull request
    Given "Tax work" shows pull request 40 which has merged
    And "feature/tax" now has the open pull request 44
    When the thread's pull requests are checked again
    Then "Tax work" shows pull request 44

  @node
  Scenario: Linked pull requests stay current
    Given pull request 42 is linked to "Tax work"
    When a review is submitted on pull request 42 on GitHub
    Then "Tax work" shows the new review state after the next sync

  @node
  Scenario: Merged links are left alone
    Given pull request 42 is linked to "Tax work" and has merged
    When the sync sweep runs
    Then pull request 42 is not read again

  @node
  Scenario: A pull request lists every thread linked to it, archived ones included
    Given pull request 42 is linked to "Tax work" and to the archived thread "Old tax"
    When the user asks which threads are linked to pull request 42
    Then both "Tax work" and "Old tax" are listed

  @backlog @desktop @mobile
  Scenario: Linking from a pull request link in the conversation
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    When the user links that pull request from the mention
    Then "Tax work" lists pull request 42

  @backlog @desktop @mobile
  Scenario: A pull request from a repository no project can read
    When the user links "https://github.com/other/repo/pull/1"
    Then the user is told no project in this environment can read "github.com/other/repo"

  @desktop @backlog-desktop
  Scenario: Opening the thread's pull request from the composer
    Given pull request 42 is the branch's pull request of "Tax work"
    When the user opens the pull request from the thread
    Then pull request 42 opens

  @backlog @mobile
  Scenario: The phone's git overview lists linked reviews and stacks
    Given pull request 42 is linked to "Tax work"
    When the user opens the git overview of "Tax work" on the phone
    Then pull request 42 is listed with its stack
