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

  @backlog @tui @mobile
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
