# Sources:
#   apps/mobile/src/features/review/ (diff source selector, viewed files, comments, notices)
#   apps/mobile/src/features/diffs/
#   apps/mobile/modules/t3-review-diff
#   apps/mobile/src/features/threads/ git routes (git actions, commit, branches, confirm)
# Diff sources, checkpoints and source control actions are specified in
# features/source-control/ and features/timeline/. This file covers reading and commenting
# on a diff on a small screen.

Feature: Reviewing changes on a phone
  A phone shows one changed file at a time in a readable width, remembers what the user has
  already looked at, and lets the user leave comments for the agent.

  Background:
    Given the phone is paired with "My MacBook"
    And the thread "Fix checkout" has changed "src/cart.ts" and "src/price.ts"

  @backlog @mobile
  Scenario Outline: The user chooses which changes to review
    When the user reviews the <source> of "Fix checkout"
    Then the diff shows the <source>

    Examples:
      | source          |
      | working tree    |
      | branch changes  |
      | latest turn     |
      | second turn     |

  @backlog @mobile
  Scenario: The list of changed files can be hidden and shown
    Given the user is reviewing "Fix checkout"
    When the user hides the changed files list
    Then only the diff is shown
    When the user shows the changed files list
    Then "src/cart.ts" and "src/price.ts" are listed

  @backlog @mobile
  Scenario: The user collapses and expands a file's diff
    Given the user is reviewing "Fix checkout"
    When the user collapses "src/cart.ts"
    Then the changes in "src/cart.ts" are hidden
    When the user expands "src/cart.ts"
    Then the changes in "src/cart.ts" are shown

  @backlog @mobile
  Scenario: The user marks a file as viewed and unmarks it
    Given the user is reviewing "Fix checkout"
    When the user marks "src/cart.ts" as viewed
    Then "src/cart.ts" is collapsed and shown as viewed
    When the user marks "src/cart.ts" as not viewed
    Then "src/cart.ts" is expanded again

  @backlog @mobile
  Scenario: Viewed files are remembered per diff source
    Given the user marked "src/cart.ts" as viewed in the latest turn
    When the user switches to the working tree and back
    Then "src/cart.ts" is still viewed in the latest turn

  @backlog @mobile
  Scenario: Changed words are highlighted within a changed line
    Given a line changed from "total = 1" to "total = 2"
    When the user reviews that line
    Then only the changed number is highlighted

  @backlog @mobile
  Scenario: The user comments on a range of lines
    Given the user is reviewing "src/cart.ts"
    When the user selects lines 10 to 14 and writes "use the helper here"
    Then the comment is attached to lines 10 to 14 in the draft for "Fix checkout"

  @backlog @mobile
  Scenario: The user adds an image to a review comment
    Given the user is writing a review comment
    When the user attaches a screenshot to it
    Then the comment carries the screenshot

  @backlog @mobile
  Scenario: The user discards a review comment
    Given the user is writing a review comment
    When the user discards it
    Then no comment is added to the draft

  @backlog @mobile
  Scenario: An empty diff says so
    Given the latest turn changed nothing
    When the user reviews the latest turn
    Then the user is told the diff is empty

  @backlog @mobile
  Scenario: A diff seen before is shown while offline
    Given the user reviewed the latest turn earlier
    And "My MacBook" is unreachable
    When the user reviews the latest turn
    Then the earlier diff is shown
    And the user is told it may be out of date

  @backlog @mobile
  Scenario: A diff never loaded cannot be shown offline
    Given "My MacBook" is unreachable
    When the user reviews branch changes for the first time
    Then the user is told the diff will load when the connection returns

  @backlog @mobile
  Scenario: Only recent diffs are kept on the phone
    Given the user has reviewed nine different diffs
    Then the phone keeps only the eight most recent diffs

  @backlog @mobile
  Scenario: Wide diffs scroll sideways without breaking the back swipe
    Given the user is reviewing a file with very long lines scrolled to their start
    When the user swipes from the leading edge
    Then the user goes back to the thread

  @backlog @mobile
  Scenario Outline: Git actions can be taken from the phone
    When the user chooses to <action> from the thread
    Then <outcome>

    Examples:
      | action                        | outcome                                         |
      | commit the changes            | the commit form opens                           |
      | switch branches               | the branch list opens                           |
      | move the thread to a worktree | the worktree form opens                         |
      | pull the latest changes       | the branch is updated from its remote           |
      | open the pull request         | the pull request opens in the browser           |

  @backlog @mobile
  Scenario: A commit message left empty is written for the user
    When the user commits with an empty commit message
    Then the commit gets a generated message

  @backlog @mobile
  Scenario: Acting on the default branch asks how to continue
    Given the thread is on the default branch
    When the user commits the changes
    Then the user is asked whether to commit on the default branch or on a new branch

  @backlog @mobile
  Scenario: Cancelling the default branch question does nothing
    Given the user is asked whether to commit on the default branch
    When the user cancels
    Then nothing is committed

  @backlog @mobile
  Scenario: A branch without a pull request says so
    Given the thread's branch has no open pull request
    When the user opens the pull request
    Then the user is told the branch does not have an open pull request

  @backlog @mobile
  Scenario: A branch checked out elsewhere is marked in the branch list
    Given "feature/search" is checked out in another worktree
    When the user opens the branch list
    Then "feature/search" is marked as checked out in another worktree
