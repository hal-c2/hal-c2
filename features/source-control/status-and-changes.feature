# Sources:
#   docs/user/source-control.md
#   packages/contracts/src/vcs.ts (VcsStatusLocalResult, VcsStatusRemoteResult, VcsStatusStreamEvent, VcsDriverKind)
#   packages/contracts/src/rpc.ts (vcs.refreshStatus, subscribeVcsStatus, vcs.init)
#   apps/server-ex/lib/hal_c2/vcs.ex (status, init)
#   apps/server-ex/lib/hal_c2/vcs/watch.ex
#   apps/server-ex/lib/hal_c2/background_policy.ex (automaticGitFetchInterval)
#   apps/web/src/components/GitActionsControl.tsx (Initialize Git)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (Initialize Git, git pill)
#   apps/tui/src/gitActions.logic.ts (mergeVcsStatus, resolveGitQuickAction)
#   apps/tui/src/connection.ts (subscribeVcsStatus)

Feature: Repository status and working tree changes
  The checkout behind a thread reports its branch, its uncommitted changes and how it stands
  against its upstream, and keeps that picture current while someone is looking at it.

  Background:
    Given a connected environment with the project "shop" in a git repository

  @mc
  Scenario: Status reports the branch and the uncommitted files
    Given the user has changed "src/cart.ts" and added "src/tax.ts" on the branch "feature/tax"
    When status is read for "shop"
    Then the status names the branch "feature/tax"
    And it lists both files with their inserted and deleted line counts
    And it says the working tree has changes

  @mc
  Scenario: Status reports how the branch stands against its upstream
    Given "feature/tax" tracks "origin/feature/tax" and is 2 commits ahead and 1 behind
    When status is read for "shop"
    Then the status says the branch has an upstream
    And it reports 2 commits ahead and 1 behind

  # Delivered natively (WorkspaceController follows the checkout's vcs status); no desktop test yet.
  @mc @desktop @tui @backlog-desktop
  Scenario: Status follows the checkout while the thread is open
    Given the user is looking at a thread in "shop"
    When the agent's turn ends after editing a file
    Then the thread's status shows the new change without the user asking for a refresh

  @mc
  Scenario: Status refreshes after a git action finishes
    Given the user is looking at a thread in "shop" with uncommitted changes
    When the user commits the changes
    Then the thread's status reports a clean working tree

  @mc
  Scenario: The remote side is fetched on the automatic fetch interval
    Given the automatic Git fetch interval is 30 seconds
    And a client in front is showing a thread in "shop"
    When 30 seconds pass
    Then the MC fetches from the remote and the ahead and behind counts are updated

  @mc
  Scenario: A fetch interval of zero never fetches on its own
    Given the automatic Git fetch interval is 0 seconds
    When a client shows a thread in "shop" for several minutes
    Then the MC never fetches from the remote without being asked

  @mc
  Scenario: Nobody watching means no background fetches
    Given no client is showing a thread in "shop"
    When the fetch interval elapses
    Then the MC does not fetch "shop" from the remote

  @mc
  Scenario: Status names the open pull request for a GitHub branch
    Given "feature/tax" has an open draft pull request on GitHub
    When status is read for "shop"
    Then the status carries that pull request with its state open and marked as a draft

  @mc
  Scenario: On the default branch only an open pull request counts
    Given "main" once had a merged pull request from the same branch name
    When status is read on "main"
    Then the status carries no pull request

  @backlog @mc
  Scenario Outline: Status names the open change request on other hosts
    Given "shop" has its primary remote on <host>
    And the current branch has an open change request there
    When status is read for "shop"
    Then the status carries that change request

    Examples:
      | host         |
      | GitLab       |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @mc
  Scenario: A folder that is not a repository says so
    Given the project "notes" is not in a git repository
    When status is read for "notes"
    Then the status says it is not a repository

  # Delivered natively (GitController, vcs.init); source-control/git-actions.feature runs it in its own words, not these steps.
  @mc @desktop @backlog-desktop
  Scenario: Initializing a repository in a plain folder
    Given the project "notes" is not in a git repository
    When the user initializes Git for "notes"
    Then "notes" becomes a git repository
    And the git actions for "notes" become available

  @backlog @tui
  Scenario: Initializing a repository from the terminal client
    Given the project "notes" is not in a git repository
    When the user initializes Git for "notes" from the terminal client
    Then "notes" becomes a git repository

  @backlog @mc
  Scenario: A Jujutsu checkout reports its status
    Given the project "shop" is a Jujutsu repository
    When status is read for "shop"
    Then the status reports the Jujutsu driver with its bookmark and working copy changes
