# Sources:
#   docs/user/source-control.md (Troubleshooting)
#   packages/contracts/src/vcs.ts (VcsProcessExitError, VcsProcessTimeoutError, VcsOutputLimitError, VcsProcessSpawnError, VcsRepositoryDetectionError, VcsUnsupportedOperationError)
#   packages/contracts/src/git.ts (GitManagerError, GitPullRequestMaterializationError, TextGenerationError)
#   packages/contracts/src/sourceControl.ts (SourceControlRepositoryError)
#   apps/server-ex/lib/hal_c2/git_actions.ex (failure messages, action_failed)
#   apps/server-ex/lib/hal_c2/vcs.ex (VcsProcessExitError)
#   apps/server-ex/lib/hal_c2/source_control.ex (SourceControlRepositoryError)
#   apps/web/src/components/GitActionsControl.logic.ts (error toasts)
#   apps/tui/src/store.ts (Git failed)
#   apps/tui/src/features.backlog.test.ts (git-operation-progress)

Feature: When source control goes wrong
  Failures name what went wrong in the user's words, keep enough detail to act on, and
  leave the status current so the user can try again.

  Background:
    Given a connected environment with a thread in the git project "shop"

  @node
  Scenario Outline: A git action refuses what it cannot do
    Given <condition>
    When the user runs "<action>"
    Then the action fails with "<message>"

    # Both servers say "Cannot push from detached HEAD." for a push (GitManager.ts, git_actions.ex).
    Examples:
      | condition                                     | action           | message                                                          |
      | the thread's folder is not a git repository   | Commit           | is not a git repository.                                         |
      | the checkout is on a detached HEAD            | Push             | Cannot push from detached HEAD.                                  |
      | the repository has no remote                  | Push             | Cannot push because no git remote is configured for this repository. |
      | the working tree has uncommitted changes      | Create PR        | Commit local changes before creating a PR.                       |
      | the GitHub CLI is not installed               | Create PR        | Creating a PR needs the GitHub CLI (gh).                         |

  @node
  Scenario: A pull request description that cannot be written stops the action
    Given the writer model is unreachable
    When the user runs "Create PR"
    Then the action fails with a message starting "Could not write the PR description:"
    And no pull request is opened

  @node
  Scenario: The host refusing a new pull request is reported
    Given GitHub refuses to open the pull request
    When the user runs "Create PR"
    Then the action fails saying the pull request could not be created, with GitHub's reason

  @node
  Scenario: A failed action still refreshes the status
    Given the push will be rejected by the remote
    When the user runs "Commit & push"
    Then the commit is kept and the status shows the branch ahead of its upstream
    And the failure is reported with the push step that failed

  @node
  Scenario: A failed git command keeps its command and exit code
    Given git exits with an error while initializing "shop"
    When the user initializes Git for "shop"
    Then the error names the git command, the folder and the exit code

  @backlog @node
  Scenario Outline: Host failures are named for what they are
    Given the host answers a push with <condition>
    When the user pushes
    Then the user is told "<message>"
    And the error says whether retrying could help

    Examples:
      | condition                  | message                     |
      | an authentication failure  | Authentication failed.      |
      | a rate limit               | API rate limit exceeded.    |
      | a missing pull request     | Pull request not found.     |
      | a missing merge request    | Merge request not found.    |

  @backlog @node
  Scenario Outline: Runaway git commands are stopped
    Given a git command <condition>
    When status is read for "shop"
    Then the user is told the command <result>

    Examples:
      | condition                      | result               |
      | runs past its time limit       | timed out            |
      | prints more than the limit     | produced too much output |
      | cannot be started              | could not be started |

  @tui
  Scenario: The terminal client reports a failed git action
    Given the push will be rejected by the remote
    When the user pushes from the terminal client
    Then the status line reads the failure starting "Git failed:"

  @backlog @tui
  Scenario: The terminal client keeps the failed phase and hook output
    Given the pre-commit hook fails with "lint failed"
    When the user commits from the terminal client
    Then the user sees that the commit phase failed and the hook printed "lint failed"

  # Delivered natively (GitController keeps a failure's toast until it is dismissed); no desktop test yet.
  @desktop @backlog-desktop
  Scenario: A failed git action stays on screen until dismissed
    Given the push will be rejected by the remote
    When the user pushes
    Then the failure stays visible until the user dismisses it

  @node
  Scenario: A repository that cannot be looked up is reported per host
    When the user looks up "acme/missing" on GitHub
    Then the user is told the repository could not be found on GitHub
