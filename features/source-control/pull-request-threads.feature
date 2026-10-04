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
#   apps/desktop-qt/src/native/ThreadPullRequests.cpp (the right panel's Pull requests tab)
#   apps/desktop-qt/qml/HalC2/Bricks/PullRequestsPanel.qml
#   apps/desktop-qt/tests/native/features/PullRequestSteps.cpp
#   apps/web/src/components/pullRequest/ThreadPullRequestsPanel.tsx
#   apps/tui/src/features.backlog.test.ts (pull request checkout)

Feature: Threads that work on or link pull requests
  A thread can start from a pull request, checked out locally or in its own worktree,
  and any thread can link the pull requests it relates to and keep them current.

  Background:
    Given a connected environment with the GitHub project "acme/shop"

  @mc
  Scenario Outline: A pull request can be named in several ways
    When the user asks to work on the pull request <reference>
    Then pull request 42 of "acme/shop" is resolved with its title, branches and state

    Examples:
      | reference                                 |
      | 42                                        |
      | #42                                       |
      | https://github.com/acme/shop/pull/42      |

  @mc
  Scenario: A pull request that does not exist
    When the user asks to work on the pull request 9999
    Then the user is told the pull request was not found

  @mc
  Scenario: Working on a pull request in the local checkout
    When the user starts a thread on pull request 42 in the local checkout
    Then the project's checkout switches to the pull request's branch
    And the new thread is linked to pull request 42

  @mc
  Scenario: Working on a pull request in its own worktree
    When the user starts a thread on pull request 42 in a new worktree
    Then the pull request's head is fetched into a worktree of its own
    And the new thread works in that worktree

  @mc
  Scenario: A pull request from a fork gets a branch of its own
    Given pull request 42 comes from the fork branch "tax"
    When the user starts a thread on pull request 42 in a new worktree
    Then the worktree is on the branch "hal-c2/pr-42/tax" with no upstream

  @mc
  Scenario: An existing worktree for the pull request is reused
    Given a worktree for pull request 42 exists with local commits
    When the user starts a thread on pull request 42 in a new worktree
    Then the existing worktree is reused
    And the user is told the checkout is not on the pull request's head

  @mc
  Scenario: A pull request branch already in the main checkout cannot get a worktree
    Given the main checkout is on pull request 42's branch
    When the user starts a thread on pull request 42 in a new worktree
    Then the user is told to use the local checkout or switch the main checkout off that branch

  @mc
  Scenario: Pull request worktrees do not run the setup script
    Given "acme/shop" has a setup script for new worktrees
    When the user starts a thread on pull request 42 in a new worktree
    Then the setup script does not run

  @backlog @desktop @mobile @tui
  Scenario: Starting a pull request thread from a pasted link
    When the user pastes "https://github.com/acme/shop/pull/42" to start a pull request thread
    Then the user sees the pull request's title and branches before choosing local or worktree

  @mc @desktop
  Scenario: Linking a pull request to a thread
    Given the thread "Tax work" has no linked pull request
    When the user links pull request 42 to "Tax work"
    Then "Tax work" lists pull request 42 with its current state

  @mc @desktop
  Scenario: Unlinking a pull request from a thread
    Given pull request 42 is linked to "Tax work"
    When the user unlinks pull request 42
    Then "Tax work" no longer lists pull request 42

  @mc @desktop
  Scenario: A thread links several pull requests across repositories
    When the user links "acme/shop" pull request 42 and "acme/api" pull request 7 to "Tax work"
    Then "Tax work" lists both pull requests

  @mc
  Scenario: The agent links the pull request it opened
    When the agent in "Tax work" opens pull request 43 and links it with its tool
    Then "Tax work" lists pull request 43

  @mc
  Scenario: Creating a pull request from a thread links it
    When the user creates a pull request from "Tax work"
    Then "Tax work" lists the new pull request

  @mc
  Scenario: The branch's pull request is discovered on its own
    Given "Tax work" is on the branch "feature/tax" with no linked pull request
    When someone opens a pull request for "feature/tax" on GitHub
    Then within a minute "Tax work" shows that pull request as its branch's

  @mc
  Scenario: A merged link moves to the branch's open pull request
    Given "Tax work" shows pull request 40 which has merged
    And "feature/tax" now has the open pull request 44
    When the thread's pull requests are checked again
    Then "Tax work" shows pull request 44

  @mc @desktop
  Scenario: Linked pull requests stay current
    Given pull request 42 is linked to "Tax work"
    When a review is submitted on pull request 42 on GitHub
    Then "Tax work" shows the new review state after the next sync

  @mc
  Scenario: Merged links are left alone
    Given pull request 42 is linked to "Tax work" and has merged
    When the sync sweep runs
    Then pull request 42 is not read again

  @mc
  Scenario: A pull request lists every thread linked to it, archived ones included
    Given pull request 42 is linked to "Tax work" and to the archived thread "Old tax"
    When the user asks which threads are linked to pull request 42
    Then both "Tax work" and "Old tax" are listed

  @desktop @mobile @backlog-mobile
  Scenario: Linking from a pull request link in the conversation
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    When the user links that pull request from the mention
    Then "Tax work" lists pull request 42

  # Links are decided by host, as the web's usePullRequestLinking and
  # findProjectOnChangeRequestHost do: any project on a host lends the MC its
  # credentials there, so a repository nobody has checked out still links.
  @desktop @mobile @backlog-mobile
  Scenario: A pull request from another repository on a host a project reads
    When the user links "https://github.com/other/repo/pull/1"
    Then "Tax work" lists pull request 1 of "other/repo"

  @desktop @mobile @backlog-mobile
  Scenario: A pull request on a host no project can read
    When the user links "https://gitlab.com/other/repo/-/merge_requests/1"
    Then the user is told no project in this environment can read "gitlab.com/other/repo"

  # Azure DevOps reads use the checkout's organization and project, not the
  # host's credentials, so there it takes a project of that repository.
  @desktop @mobile @backlog-mobile
  Scenario: An Azure DevOps pull request needs a project of its own repository
    Given the environment also has the Azure DevOps project "dev.azure.com/acme/shop/_git/web"
    When the user links "https://dev.azure.com/acme/shop/_git/api/pullrequest/1"
    Then the user is told no project in this environment can read "dev.azure.com/acme/shop/_git/api"
    When the user links "https://dev.azure.com/acme/shop/_git/web/pullrequest/1"
    Then "Tax work" lists pull request 1 of "acme/shop/_git/web"

  @desktop @mobile @backlog-mobile
  Scenario: A pull request the MC does not link says why
    Given the thread "Tax work" has no linked pull request
    And the MC refuses to link pull requests to "Tax work"
    When the user links pull request 42 to "Tax work"
    Then the user is told pull request 42 could not be linked
    And "Tax work" lists no pull requests

  @desktop @mobile @backlog-mobile
  Scenario: Opening a linked pull request in the browser
    Given pull request 42 is linked to "Tax work"
    When the user opens pull request 42 from "Tax work"
    Then the browser opens "https://github.com/acme/shop/pull/42"

  @desktop @mobile @backlog-mobile
  Scenario: Refreshing the linked pull requests reads them from the host again
    Given pull request 42 is linked to "Tax work"
    And a review is submitted on pull request 42 on GitHub
    When the user refreshes the pull requests of "Tax work"
    Then pull request 42 is read from GitHub again
    And "Tax work" shows the new review state

  @desktop @mobile @backlog-mobile
  Scenario: Linked pull requests of an unreachable environment stay as last synced
    Given pull request 42 is linked to "Tax work"
    When the environment of "Tax work" becomes unreachable
    Then "Tax work" still lists pull request 42
    And the user cannot link, unlink or refresh pull requests
    When the environment of "Tax work" is reachable again
    Then the user can link, unlink and refresh pull requests

  @desktop
  Scenario: Opening the thread's pull request from the composer
    Given pull request 42 is the branch's pull request of "Tax work"
    When the user opens the pull request from the thread
    Then pull request 42 opens

  @backlog @mobile
  Scenario: The phone's git overview lists linked reviews and stacks
    Given pull request 42 is linked to "Tax work"
    When the user opens the git overview of "Tax work" on the phone
    Then pull request 42 is listed with its stack
