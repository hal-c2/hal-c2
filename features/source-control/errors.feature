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
#   apps/server/src/vcs/GitVcsDriverCore.ts (fetchFailureDetail, non-interactive fetch), VcsProcess.ts
#   apps/server/src/git/GitWorkflowService.ts (git-only workflows)
#   apps/server/src/sourceControl/SourceControlProvider.ts (transportSafeSourceControlErrorValue)

Feature: When source control goes wrong
  Failures name what went wrong in the user's words, keep enough detail to act on, and
  leave the status current so the user can try again.

  Background:
    Given a connected environment with a thread in the git project "shop"

  @mc
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

  # Legacy: apps/server/src/git/GitWorkflowService.ts (ensureGit, ensureGitCommand)
  @mc @backlog
  Scenario Outline: A git workflow refuses a checkout that is not a git repository
    Given the thread's folder is a Jujutsu checkout
    When the user runs "<action>"
    Then the action fails with "The GitWorkflowService.<workflow> workflow currently supports Git repositories only; detected jj."
    And nothing in the checkout is changed

    Examples:
      | action         | workflow                    |
      | Commit         | runStackedAction            |
      | Pull           | pullCurrentBranch           |
      | New worktree   | createWorktree              |
      | Rename branch  | renameBranch                |

  @mc
  Scenario: A pull request description that cannot be written stops the action
    Given the writer model is unreachable
    When the user runs "Create PR"
    Then the action fails with a message starting "Could not write the PR description:"
    And no pull request is opened

  @mc
  Scenario: The host refusing a new pull request is reported
    Given GitHub refuses to open the pull request
    When the user runs "Create PR"
    Then the action fails saying the pull request could not be created, with GitHub's reason

  @mc
  Scenario: A failed action still refreshes the status
    Given the push will be rejected by the remote
    When the user runs "Commit & push"
    Then the commit is kept and the status shows the branch ahead of its upstream
    And the failure is reported with the push step that failed

  @mc
  Scenario: A failed git command keeps its command and exit code
    Given git exits with an error while initializing "shop"
    When the user initializes Git for "shop"
    Then the error names the git command, the folder and the exit code

  @backlog @mc
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

  @mc
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

  @tui
  Scenario: The terminal client keeps the failed phase and hook output
    Given the pre-commit hook fails with "lint failed"
    When the user commits from the terminal client
    Then the user sees that the commit phase failed and the hook printed "lint failed"

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (fetchFailureDetail)
  @mc @backlog
  Scenario Outline: A fetch that fails says what to check
    Given git answers a fetch with <output>
    When the MC fetches the remote of "shop"
    Then the failure says "<message>"

    Examples:
      | output                                              | message                                                                                                    |
      | "fatal: Authentication failed"                      | Git could not authenticate with the remote. Check Git credentials or SSH access on the server, then retry. |
      | "Permission denied (publickey)"                     | Git could not authenticate with the remote. Check Git credentials or SSH access on the server, then retry. |
      | "Could not resolve hostname"                        | Git could not reach the remote. Check the server's network connection and remote host, then retry.        |
      | "ssh: connect to host port 22: Connection refused"  | Git could not reach the remote. Check the server's network connection and remote host, then retry.        |
      | "remote: Repository not found."                     | Git could not access the remote repository. Check the remote URL and repository permissions on the server. |
      | "fatal: cannot lock ref"                            | Git could not update a local reference. Another Git operation or a stale lock may be blocking the fetch; check the repository on the server, then retry. |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (STATUS_UPSTREAM_REFRESH_ENV, fetchRemote)
  @mc @backlog
  Scenario: A background fetch never stops to ask for a password
    Given the remote of "shop" needs a password that git has not stored
    When the MC fetches the remote in the background
    Then the fetch fails at once with the authentication failure
    And no password prompt is shown on the machine

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (fetchRemote with a branch)
  @mc @backlog
  Scenario: A fetch for one branch the remote no longer has fetches the remote instead
    Given "feature/tax" was deleted on the remote
    When the MC fetches "feature/tax" from the remote
    Then the rest of the remote is fetched and the fetch succeeds

  # Delivered natively (GitController keeps a failure's toast until it is dismissed); no desktop test yet.
  @desktop
  Scenario: A failed git action stays on screen until dismissed
    Given the push will be rejected by the remote
    When the user pushes
    Then the failure stays visible until the user dismisses it

  @mc
  Scenario: A repository that cannot be looked up is reported per host
    When the user looks up "acme/missing" on GitHub
    Then the user is told the repository could not be found on GitHub

  # Legacy: apps/server/src/sourceControl/SourceControlProvider.ts (transportSafeSourceControlErrorValue)
  @mc @backlog
  Scenario Outline: A repository or link named in a failure carries no secrets
    When the user looks up <named> and the host refuses it
    Then the failure names <shown>

    Examples:
      | named                                                    | shown                                           |
      | "https://sam:s3cret@example.com/acme/shop.git?token=abc" | "https://example.com/acme/shop.git"             |
      | "https://example.com/acme/shop#readme"                   | "https://example.com/acme/shop"                 |
      | "acme/shop" typed with a line break and a tab inside     | "acme/shop" with each one shown as a space      |
      | a name of 1,000 characters                               | its first 256 characters                        |
