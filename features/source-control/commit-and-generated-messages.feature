# Sources:
#   docs/user/source-control.md (Commit, push and PR with generated messages)
#   packages/contracts/src/git.ts (GitStackedAction, GitRunStackedActionInput, GitActionProgressEvent)
#   packages/contracts/src/rpc.ts (git.runStackedAction)
#   apps/server-ex/lib/hal_c2/git_actions.ex
#   apps/server-ex/lib/hal_c2/text_generation.ex (commit_message, branch_name)
#   apps/server-ex/lib/hal_c2/text_generation/style.ex (policy, pr_template)
#   apps/server-ex/lib/hal_c2/text_generation.ex (pr_content)
#   apps/web/src/components/GitActionsControl.tsx (commit dialog)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (commit dialog)
#   apps/desktop-qt/src/native/GitController.cpp (runs the desktop's actions through gitAction, its toasts)
#   apps/server-ex/lib/hal_c2/web/socket.ex (a cluster member's requests)
#   apps/desktop-qt/tests/tst_GitActions.qml
#   apps/tui/src/components/ChatView.tsx (onRunGitAction, commit message prompt)
#   apps/tui/src/store.ts (runGitAction)
#   apps/server/src/textGeneration/TextGenerationUtils.ts (commit subject cap, PR title fallback)
#   apps/server/src/git/GitManager.ts (runPrStep: reuse, base branch, bounded context, body file)

Feature: Committing with written or generated messages
  The user reviews what goes into a commit, may leave the message to the writer model,
  and may move the work onto a new branch as part of the commit.

  Background:
    Given a connected environment with a thread in the git project "shop"
    And the user has changed "src/cart.ts" and "src/tax.ts"

  @mc @desktop @tui
  Scenario: Committing with a message the user wrote
    When the user commits with the message "Add tax to the cart"
    Then a commit "Add tax to the cart" holds both files
    And the user is told the commit was made with its short hash

  @mc @desktop
  Scenario: A blank message is written by the writer model
    When the user commits without writing a message
    Then the writer model writes the commit message from the staged diff
    And the commit is made with that message

  @backlog @mc
  Scenario Outline: The commit subject the writer gives is cleaned up
    When the writer model answers the commit message <raw>
    Then the commit subject is <subject>

    Examples:
      | raw                                  | subject                                  |
      | a subject longer than 72 characters  | cut to at most 72 characters             |
      | empty                                | "Update project files"                   |

  @tui
  Scenario: A blank message is written for the user in the terminal client
    When the user commits from the terminal client without writing a message
    Then the writer model writes the commit message

  @tui
  Scenario: The terminal client asks for a message before committing
    When the user commits from the terminal client with an empty message
    Then nothing is committed
    And the status line reads "Commit needs a message."

  @mc @desktop
  Scenario: Committing only the files the user picked
    When the user leaves "src/tax.ts" out of the commit and commits
    Then the commit holds only "src/cart.ts"
    And "src/tax.ts" is still changed in the working tree

  @desktop
  Scenario: Leaving every file out disables committing
    When the user leaves every file out of the commit
    Then neither committing nor committing on a new branch is possible

  @desktop @tui
  Scenario: Cancelling the commit leaves everything as it was
    When the user starts a commit and then cancels it
    Then nothing is committed and both files are still changed

  @desktop
  Scenario: Committing on the default branch carries a warning
    Given the checkout is on the default branch "main"
    When the user starts a commit
    Then the user is warned that the commit lands on "main"

  @mc @desktop
  Scenario: Committing on a new branch
    Given the checkout is on the default branch "main"
    When the user commits on a new branch with the message "Add tax to the cart"
    Then a branch named after the message under "feature/" is created and checked out
    And the commit is made on that branch

  @mc
  Scenario: A new branch name that is taken gets a number
    Given a branch "feature/add-tax" already exists
    When the user commits on a new branch with the message "Add tax"
    Then the new branch is "feature/add-tax-2"

  @mc
  Scenario: A new branch needs something to commit
    Given the working tree is clean
    When the user asks to commit on a new branch
    Then the action fails with "Cannot create a feature branch because there are no changes to commit."

  @mc
  Scenario: Only commit actions may move onto a new branch
    When the user asks to push on a new branch
    Then the action fails with "Feature-branch checkout is only supported for commit actions."

  @mc
  Scenario Outline: The generated message follows the writing style
    Given the project's source control writing style is <style>
    When the user commits without writing a message
    Then the writer model is told to <instruction>

    Examples:
      | style                  | instruction                                                         |
      | Repository conventions | follow the repository's recent commit subjects and AGENTS.md         |
      | Conventional Commits   | use Conventional Commits with the narrowest accurate type            |
      | Custom instructions    | follow the user's own instructions                                   |

  @mc
  Scenario: Repository conventions read CLAUDE.md only when Claude writes
    Given the writing style is Repository conventions and the writer model is a Claude model
    When the user commits without writing a message
    Then the writer model also sees the repository's CLAUDE.md

  @mc
  Scenario Outline: A generated pull request follows the writing style
    Given the project's source control writing style is <style>
    When the user commits, pushes and opens a pull request without writing its text
    Then the writer model is told to <instruction> for the pull request title and description

    Examples:
      | style                  | instruction                                                                |
      | Repository conventions | follow the repository's pull request style, recent subjects and AGENTS.md |
      | Conventional Commits   | keep the title concise without forcing Conventional Commit syntax         |
      | Custom instructions    | follow the user's own instructions                                        |

  @backlog @mc
  Scenario: A pull request title the writer leaves empty falls back to a generic title
    When the writer model answers the pull request title with nothing
    Then the pull request title is "Update project changes"

  # Legacy: apps/server/src/git/GitManager.ts (runPrStep: findOpenPr before generating)
  @mc @backlog
  Scenario: A branch that already has an open pull request gets no second one
    Given the branch "feature/tax" is pushed and has the open pull request #42
    When the user runs "Create PR"
    Then no text is written and nothing is created on the host
    And the result is the existing pull request #42 with its link

  # Legacy: apps/server/src/git/GitManager.ts (runPrStep)
  @mc @backlog
  Scenario: A pull request is not created for a branch that was never pushed
    Given the branch "feature/tax" has commits and no upstream
    When the user runs "Create PR" without pushing
    Then the action fails with "Current branch has not been pushed. Push before creating a PR."

  # Legacy: apps/server/src/git/GitManager.ts (runPrStep)
  @mc @backlog
  Scenario: A pull request is not created from a detached checkout
    Given the checkout is on a detached HEAD
    When the user runs "Create PR"
    Then the action fails with "Cannot create a pull request from detached HEAD."

  # Legacy: apps/server/src/git/GitManager.ts (resolveBaseBranch)
  @mc @backlog
  Scenario Outline: The pull request goes to the branch the checkout was set up to target
    Given <situation>
    When the user runs "Create PR"
    Then the pull request targets "<base>"

    Examples:
      | situation                                                                              | base    |
      | "feature/tax" has the recorded merge base "release" and the host's default is "main"   | release |
      | "feature/tax" tracks "origin/develop" and is not from a fork                           | develop |
      | "feature/tax" tracks a branch of the same name and the host's default is "trunk"       | trunk   |
      | the host cannot be asked and the remote's default branch is "master"                   | master  |
      | nothing records a default branch                                                       | main    |

  # Legacy: apps/server/src/git/GitManager.ts (resolveBaseRangeRef)
  @mc @backlog
  Scenario: The pull request text describes the changes since the base as the remote has it
    Given the local "main" is behind "origin/main"
    When the user runs "Create PR" for a branch based on "main"
    Then the writer is given the commits and changes since "origin/main"

  # Legacy: apps/server/src/git/GitManager.ts (runPrStep: limitContext 20,000 / 20,000 / 60,000)
  @mc @backlog
  Scenario Outline: The writer is given a bounded view of a large pull request
    Given the branch has a <part> longer than <limit> characters
    When the user runs "Create PR"
    Then the writer is given at most <limit> characters of the <part>

    Examples:
      | part              | limit  |
      | commit list       | 20,000 |
      | summary of files  | 20,000 |
      | patch             | 60,000 |

  # Legacy: apps/server/src/git/GitManager.ts (runPrStep: bodyFile)
  @mc @backlog
  Scenario: The written description is handed to the host through a file that is removed afterwards
    When the user runs "Create PR" and the host accepts or refuses the pull request
    Then the description file in the MC's temporary folder is gone
    And a description that cannot be written there fails the action with "Failed to write pull request body temp file."

  # mc/orchestration/text-generation.feature holds which pull request template the writer
  # is given, and which model writes commits, pull requests and branch names.
  @mc
  Scenario: A commit message that cannot be written fails the action
    Given the writer model is unreachable
    When the user commits without writing a message
    Then the action fails with a message starting "Could not write a commit message:"
    And nothing is committed

  @mc
  Scenario: Commit hook output is streamed while the hook runs
    Given the repository has a pre-commit hook that prints "lint ok"
    When the user commits
    Then the action reports the hook starting, its output "lint ok" and the hook finishing

  @mc
  Scenario: A git that a commit hook runs prints to the hook as it would anywhere
    Given the repository has a pre-commit hook that prints "inside: " and what "git rev-parse --is-inside-work-tree 2>&1" prints
    When the user commits
    Then the action reports the hook starting, its output "inside: true" and the hook finishing

  @mc
  Scenario: A commit hook that prints what looks like git's trace has it reported as output
    Given the repository has a pre-commit hook that prints a line shaped like a git trace record
    When the user commits
    Then the action reports the hook starting, that line as its output and the hook finishing

  @mc
  Scenario: A failing commit hook's output and exit code are reported before the commit fails
    Given the repository has a pre-commit hook that prints "lint failed" without a newline and exits with 3
    When the user commits
    Then the hook's output "lint failed" is reported before it finishes with exit code 3
    And the action fails with "lint failed"
    And nothing is committed

  @desktop @mobile @tui @backlog-mobile
  Scenario: The running action shows its stage, elapsed time and last hook line
    Given the repository has a slow pre-commit hook
    When the user commits without writing a message
    Then the user sees "Generating commit message..." and then "Committing..." with the elapsed time
    And the last line the hook printed

  @tui
  Scenario: Committing with nothing to commit in the terminal client
    Given the working tree is clean
    When the user runs a commit from the terminal client
    Then the status line reads "Nothing to commit."

  @tui
  Scenario: Commit and push with a clean tree only pushes
    Given the working tree is clean and the branch is ahead of its upstream
    When the user runs commit and push from the terminal client
    Then no commit message is asked for and the branch is pushed

  @desktop
  Scenario: Opening a changed file from the commit review
    When the user opens "src/cart.ts" from the commit review
    Then the file opens in the user's editor

  @desktop
  Scenario: No editor to open a changed file in
    Given no editor is available on this environment
    When the user opens "src/cart.ts" from the commit review
    Then the user is told "Editor opening is unavailable."

  @desktop
  Scenario: The progress toast names the stage and the hook's last line
    Given the pre-commit hook prints "lint ok" and waits
    When the user starts committing with the message "Add tax"
    Then the user sees a "loading" toast "Committing..." saying "lint ok"
    When the hook finishes
    Then the toast "Committing..." is gone
    And the user sees a "success" toast "Committed abc0001" saying "Add tax"

  @desktop
  Scenario: A failed action is reported
    Given the MC fails the action with "pre-commit hook failed"
    When the user starts committing with the message "Add tax"
    Then the user sees an "error" toast "Action failed" saying "pre-commit hook failed"

  @desktop
  Scenario: A commit offers to push it
    When the user commits with the message "Add tax"
    And the user chooses "Push" on the toast "Committed abc0001"
    Then the MC is asked to push

  @desktop
  Scenario: A git action on another machine of the cluster runs there
    Given the MC is clustered with "mc-c", which serves "env-c"
    And "env-c" has the thread "t7" titled "Deploy" in "shop" on the branch "feature/tax"
    When the user goes to "env-c:t7"
    And the user commits with the message "Add tax"
    Then the action ran on "env-c"
    And a commit "Add tax" holds both files
