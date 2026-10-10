# Sources:
#   docs/user/source-control.md
#   packages/contracts/src/git.ts (GitRunStackedActionResult, GitActionToastCta)
#   packages/contracts/src/rpc.ts (git.runStackedAction, vcs.pull)
#   apps/server-ex/lib/hal_c2/git_actions.ex (push step, toast)
#   apps/server-ex/lib/hal_c2/vcs.ex (pull)
#   apps/server-ex/lib/hal_c2/projects.ex (auto_pull), apps/server-ex/lib/hal_c2/application.ex (boot task)
#   packages/contracts/src/settings.ts (defaultAutoPull)
#   apps/web/src/components/GitActionsControl.logic.ts (default-branch confirmation, toasts)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (default-branch dialog)
#   apps/desktop-qt/src/native/GitController.cpp (runs the desktop's actions through gitAction)
#   apps/desktop-qt/qml/HalC2/Bricks/Notifications.qml
#   apps/tui/src/store.ts (pullGit, runGitAction)
#   apps/server/src/vcs/GitVcsDriverCore.ts (resolvePushRemoteName)
#   apps/server/src/vcs/GitVcsDriverCore.ts (pushCurrentBranch: base-branch upstream, aliases, chosen remote)

Feature: Pushing, pulling and guarding the default branch
  Pushing publishes the branch to its upstream, pulling only fast-forwards, and anything
  that would land on the default branch asks first.

  Background:
    Given a connected environment with a thread in the git project "shop" with the remote "origin"

  @mc @desktop @tui
  Scenario: Pushing a branch that tracks an upstream
    Given "feature/tax" tracks "origin/feature/tax" and is 1 commit ahead
    When the user pushes
    Then "origin/feature/tax" has the new commit
    # Both servers name only the upstream for a plain push: "Pushed to origin/feature/tax" (GitManager.ts, git_actions.ex).
    And the user is told where the branch was pushed

  @mc
  Scenario: The first push sets the upstream on the primary remote
    Given "feature/tax" has never been pushed
    When the user pushes
    Then the branch is pushed to "origin/feature/tax" and tracks it from now on

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (resolvePushRemoteName)
  @mc @backlog
  Scenario Outline: The first push goes to the remote the repository's settings name
    Given "feature/tax" has never been pushed
    And <settings>
    When the user pushes
    Then the branch is pushed to "<remote>"

    Examples:
      | settings                                                                              | remote                  |
      | the branch is set to push to "fork" and the repository's push default is "backup"     | fork/feature/tax        |
      | the repository's push default is "backup" and the branch has no push remote           | backup/feature/tax      |
      | no push remote or push default is set and "origin" and "upstream" exist               | origin/feature/tax      |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (pushCurrentBranch: upstream is the branch's base)
  @mc @backlog
  Scenario: A branch cut from another branch is pushed under its own name
    Given "feature/tax" was cut from "origin/dev" and tracks it
    And "feature/tax" is 1 commit ahead
    When the user pushes
    Then "origin/feature/tax" has the new commit and "origin/dev" is unchanged
    And "feature/tax" tracks "origin/feature/tax" from now on
    And "dev" is remembered as the base the pull request will target

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (pushCurrentBranch: isAliasOfUpstreamHead)
  @mc @backlog
  Scenario: A branch that tracks a remote branch of the same name under another prefix is pushed to it
    Given the local branch "upstream/effect-atom" tracks "origin/effect-atom"
    And "upstream/effect-atom" is 1 commit ahead
    When the user pushes
    Then "origin/effect-atom" has the new commit

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (pushCurrentBranch: remoteName option)
  @mc @backlog
  Scenario: Pushing to a chosen remote publishes the branch there and tracks it
    Given "feature/tax" tracks "origin/feature/tax" and is 1 commit ahead
    And the repository also has the remote "fork"
    When the user pushes "feature/tax" to "fork"
    Then "fork/feature/tax" has the new commit
    And "feature/tax" tracks "fork/feature/tax" from now on

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (pushCurrentBranch: resolvePublishBranchName)
  @mc @backlog
  Scenario: A branch named after a remote branch is published without the remote's prefix
    Given the checkout is on a local branch named "origin/hotfix"
    When the user pushes it to "origin"
    Then "origin/hotfix" has the new commit

  @mc
  Scenario: Pushing an up to date branch does nothing
    Given "feature/tax" is level with its upstream
    When the user pushes
    Then nothing is pushed and the push step is reported as already up to date

  @mc
  Scenario: The result of a push offers the next step
    Given "feature/tax" is not the default branch and has no pull request
    When the user pushes
    Then the result offers to create a pull request

  @mc
  Scenario: The result of a commit offers to push it
    When the user commits on a branch with an upstream
    Then the result offers to push the commit

  @desktop
  Scenario: A finished action's result goes away by itself
    When a push finishes
    Then the user is told what was pushed
    And the message goes away by itself after a while

  @mc @desktop @tui
  Scenario: Pulling fast-forwards the branch
    Given "feature/tax" is 2 commits behind its upstream and has no local commits
    When the user pulls
    Then the branch has the 2 new commits

  @desktop
  Scenario: A refused pull is reported
    Given "feature/tax" is 2 commits behind its upstream and has no local commits
    And the MC refuses to pull with "Cannot fast-forward."
    When the user pulls
    Then the user sees an "error" toast "Pull failed" saying "Cannot fast-forward."

  @mc
  Scenario: Pulling a diverged branch is refused
    Given "feature/tax" is 1 commit ahead and 1 behind its upstream
    When the user pulls
    Then the pull fails without merging or rebasing anything

  @mc
  Scenario Outline: Pulling is refused when there is nothing to pull from
    Given the checkout <state>
    When the user pulls
    Then the pull fails with "<message>"

    Examples:
      | state                     | message                                                                |
      | is on a detached HEAD     | Cannot pull from detached HEAD.                                        |
      | has no upstream           | Current branch has no upstream configured. Push with upstream first.   |

  # The desktop runs the first three rows. On the default branch it never offers "Commit, push & PR"
  # (GitController decides as gitActions.logic.ts does), so that row has no desktop test.
  @desktop
  Scenario Outline: Actions that would land on the default branch ask first
    Given the checkout is on the default branch "main"
    When the user runs "<action>"
    Then the user is asked to confirm before anything reaches "main"

    Examples:
      | action            |
      | Push              |
      | Create PR         |
      | Commit & push     |

    @backlog-desktop
    Examples:
      | action            |
      | Commit, push & PR |

  @desktop
  Scenario: Continuing on the default branch
    Given the user was asked to confirm pushing to "main"
    When the user continues
    Then the push runs against "main"

  @desktop
  Scenario: Aborting on the default branch
    Given the user was asked to confirm pushing to "main"
    When the user aborts
    Then nothing is committed or pushed

  @desktop
  Scenario: Moving the work onto a new branch instead
    Given the user was asked to confirm committing and pushing to "main"
    When the user chooses to create a feature branch and continue
    Then the work is committed on a new branch and pushed there instead of "main"

  @tui @mobile @backlog-mobile
  Scenario: The default-branch confirmation on the terminal client and phone
    Given the checkout is on the default branch "main"
    When the user runs "Commit & push"
    Then the user is asked to confirm before anything reaches "main"

  @mc
  Scenario: A project set to pull automatically is brought up to date when the MC starts
    Given "shop" is set to pull automatically
    And its checkout is clean on "main" and 2 commits behind "origin/main"
    When the MC starts
    Then "main" is fast-forwarded to "origin/main"

  @mc
  Scenario Outline: Pulling at start skips a checkout that <situation>
    Given "shop" is set to pull automatically
    And its checkout <situation>
    When the MC starts
    Then the checkout is left as it was

    Examples:
      | situation                              |
      | has uncommitted changes                |
      | is on a branch other than the default  |
      | has no upstream                        |
      | has commits of its own to push         |
      | has nothing new to pull                |

  @mc
  Scenario: Projects sharing a checkout pull it once at start
    Given two projects set to pull automatically share one checkout that is behind its upstream
    When the MC starts
    Then the checkout is pulled once

  @mc
  Scenario: A failed pull at start is logged and does not stop the MC
    Given "shop" is set to pull automatically and is behind its upstream
    And the pull fails
    When the MC starts
    Then the failure is written to the MC's log
    And the MC finishes starting
