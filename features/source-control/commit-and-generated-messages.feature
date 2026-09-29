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
#   apps/desktop-qt/src/native/GitController.cpp (runs the desktop's actions through gitAction)
#   apps/desktop-qt/tests/tst_GitActions.qml
#   apps/tui/src/components/ChatView.tsx (onRunGitAction, commit message prompt)
#   apps/tui/src/store.ts (runGitAction)

Feature: Committing with written or generated messages
  The user reviews what goes into a commit, may leave the message to the writer model,
  and may move the work onto a new branch as part of the commit.

  Background:
    Given a connected environment with a thread in the git project "shop"
    And the user has changed "src/cart.ts" and "src/tax.ts"

  @node @desktop @tui
  Scenario: Committing with a message the user wrote
    When the user commits with the message "Add tax to the cart"
    Then a commit "Add tax to the cart" holds both files
    And the user is told the commit was made with its short hash

  @node @desktop
  Scenario: A blank message is written by the writer model
    When the user commits without writing a message
    Then the writer model writes the commit message from the staged diff
    And the commit is made with that message

  @backlog @tui
  Scenario: A blank message is written for the user in the terminal client
    When the user commits from the terminal client without writing a message
    Then the writer model writes the commit message

  @tui
  Scenario: The terminal client asks for a message before committing
    When the user commits from the terminal client with an empty message
    Then nothing is committed
    And the status line reads "Commit needs a message."

  @node @desktop
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

  @node @desktop
  Scenario: Committing on a new branch
    Given the checkout is on the default branch "main"
    When the user commits on a new branch with the message "Add tax to the cart"
    Then a branch named after the message under "feature/" is created and checked out
    And the commit is made on that branch

  @node
  Scenario: A new branch name that is taken gets a number
    Given a branch "feature/add-tax" already exists
    When the user commits on a new branch with the message "Add tax"
    Then the new branch is "feature/add-tax-2"

  @node
  Scenario: A new branch needs something to commit
    Given the working tree is clean
    When the user asks to commit on a new branch
    Then the action fails with "Cannot create a feature branch because there are no changes to commit."

  @node
  Scenario: Only commit actions may move onto a new branch
    When the user asks to push on a new branch
    Then the action fails with "Feature-branch checkout is only supported for commit actions."

  @node
  Scenario Outline: The generated message follows the writing style
    Given the project's source control writing style is <style>
    When the user commits without writing a message
    Then the writer model is told to <instruction>

    Examples:
      | style                  | instruction                                                         |
      | Repository conventions | follow the repository's recent commit subjects and AGENTS.md         |
      | Conventional Commits   | use Conventional Commits with the narrowest accurate type            |
      | Custom instructions    | follow the user's own instructions                                   |

  @node
  Scenario: Repository conventions read CLAUDE.md only when Claude writes
    Given the writing style is Repository conventions and the writer model is a Claude model
    When the user commits without writing a message
    Then the writer model also sees the repository's CLAUDE.md

  @node
  Scenario Outline: A generated pull request follows the writing style
    Given the project's source control writing style is <style>
    When the user commits, pushes and opens a pull request without writing its text
    Then the writer model is told to <instruction> for the pull request title and description

    Examples:
      | style                  | instruction                                                                |
      | Repository conventions | follow the repository's pull request style, recent subjects and AGENTS.md |
      | Conventional Commits   | keep the title concise without forcing Conventional Commit syntax         |
      | Custom instructions    | follow the user's own instructions                                        |

  # node/orchestration/text-generation.feature holds which pull request template the writer
  # is given, and which model writes commits, pull requests and branch names.
  @node
  Scenario: A commit message that cannot be written fails the action
    Given the writer model is unreachable
    When the user commits without writing a message
    Then the action fails with a message starting "Could not write a commit message:"
    And nothing is committed

  @node
  Scenario: Commit hook output is streamed while the hook runs
    Given the repository has a pre-commit hook that prints "lint ok"
    When the user commits
    Then the action reports the hook starting, its output "lint ok" and the hook finishing

  @backlog @desktop @mobile @tui
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

  @backlog @desktop
  Scenario: Opening a changed file from the commit review
    When the user opens "src/cart.ts" from the commit review
    Then the file opens in the user's editor

  @backlog @desktop
  Scenario: No editor to open a changed file in
    Given no editor is available on this environment
    When the user opens "src/cart.ts" from the commit review
    Then the user is told "Editor opening is unavailable."
