# Sources:
#   apps/mobile/src/features/review/ (diff source selector, viewed files, comments, notices)
#   apps/mobile/src/features/diffs/
#   apps/mobile/modules/hal-c2-review-diff
#   apps/mobile/src/features/threads/ git routes (git actions, commit, branches, confirm)
#   apps/mobile/src/features/threads/git/ (GitOverviewSheet, GitCommitSheet, GitBranchesSheet, GitConfirmSheet: status line, pull row, file selection, branch rows, worktree base)
#   apps/mobile/src/features/threads/ThreadGitControls.tsx (git menu line, truncated branch name, git unavailable, merge back)
#   apps/mobile/src/features/threads/GitActionProgressOverlay.tsx (progress, result and failure notice)
#   apps/mobile/src/state/use-vcs-action-state.ts (latest output line, elapsed seconds, notice dismissed after 5 seconds)
#   apps/mobile/src/state/use-selected-thread-git-actions.ts (pull notices, new worktree becomes the checkout, refused changes)
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
  Scenario: Code in a diff is coloured by the file's language
    Given the diff of "src/cart.ts" is open
    Then the lines of "src/cart.ts" are coloured as TypeScript
    And a multi-line comment or string keeps its colour across the lines it spans

  @backlog @mobile
  Scenario: A very long line in a diff stays plain while the lines after it are still coloured
    Given the diff of "src/cart.ts" contains a line of more than 1,000 characters
    When the user reads the diff
    Then that line is shown without colour
    And the lines after it are coloured as usual

  @backlog @mobile
  Scenario: Words are not marked inside a very long changed line
    Given a changed line of more than a thousand characters
    When the user reviews that line
    Then the whole line is marked as changed without marking single words

  @backlog @mobile
  Scenario: A large file's diff is held back until the user asks for it
    Given "src/big.ts" has a diff of more than 400 rows
    When the user reviews the changes
    Then "src/big.ts" says its diff is large and offers to load it
    When the user asks to load the diff
    Then the rows of "src/big.ts" are shown

  @backlog @mobile
  Scenario: A non-text file shows no diff
    Given the thread changed the image "assets/icon.png"
    When the user reviews the changes
    Then "assets/icon.png" is listed as a non-text file
    And no diff rows are offered for it

  @backlog @mobile
  Scenario: A diff cut short by the server is shown as partial and keeps whole-file counts
    Given the patch of "src/cart.ts" arrived truncated
    When the user reviews the changes
    Then the rows that arrived are shown
    And the file is marked as a partial preview
    And its added and removed counts still cover the whole file

  @backlog @mobile
  Scenario: The user comments on a range of lines
    Given the user is reviewing "src/cart.ts"
    When the user selects lines 10 to 14 and writes "use the helper here"
    Then the comment is attached to lines 10 to 14 in the draft for "Fix checkout"

  @backlog @mobile
  Scenario: Tapping a line starts a comment on that line
    Given the user is reviewing "src/cart.ts"
    When the user taps line 10
    Then a comment on line 10 is started

  @backlog @mobile
  Scenario: Touching and holding a line then tapping another comments on the range
    Given the user is reviewing "src/cart.ts"
    When the user touches and holds line 10
    Then line 10 is marked as the start of a range
    When the user taps line 14
    Then a comment on lines 10 to 14 is started

  @backlog @mobile
  Scenario: A range cannot be carried into another file
    Given the user touched and held line 10 of "src/cart.ts"
    When the user taps line 3 of "src/price.ts"
    Then a comment on line 3 of "src/price.ts" is started
    And line 10 of "src/cart.ts" is no longer marked

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
  Scenario: The user comments on a whole file
    Given the user is reviewing "src/cart.ts"
    When the user comments on the file without selecting lines
    Then the comment is labelled as a file comment
    And it is attached to "src/cart.ts" in the draft for "Fix checkout"

  @backlog @mobile
  Scenario Outline: A review comment names what it is about
    Given the user selected <selection> of "src/cart.ts"
    When the user starts a review comment
    Then the comment is headed "<heading>"

    Examples:
      | selection        | heading    |
      | line 10          | Line 10    |
      | lines 10 to 14   | Lines 10-14 |

  @backlog @mobile
  Scenario: A long selection is previewed in a few lines that scroll
    Given the user selected twelve lines of "src/cart.ts"
    When the user starts a review comment
    Then five lines of the selection are previewed
    And the preview scrolls to show the rest

  @backlog @mobile
  Scenario: A comment that mentions markup is shown as written
    Given the user wrote a review comment that contains a closing tag and "a > b"
    When the message is sent and read back on the phone
    Then the comment is shown with exactly that text

  @backlog @mobile
  Scenario: A review comment shows the lines it is about
    Given the draft for "Fix checkout" carries a comment on lines 10 to 14 of "src/cart.ts"
    Then the comment is shown with the file name, its line range and the commented lines as a diff
    When the message is sent
    Then the sent message shows the same comment and lines in the timeline

  @backlog @mobile
  Scenario: A comment written on the desktop's file viewer is shown the same way
    Given a message carries a comment on lines 12 to 14 of "src/cart.ts" written on another client
    When the user reads the message on the phone
    Then the comment is shown with its file name, its line range and the lines in the language of the file

  @backlog @mobile
  Scenario: An empty diff says so
    Given the latest turn changed nothing
    When the user reviews the latest turn
    Then the user is told the diff is empty

  @backlog @mobile
  Scenario: A thread with nothing to review says so
    Given "Fix checkout" has no ready turn diffs and its worktree has no changes
    When the user reviews the changes
    Then the user is told there are no review diffs
    And the user is told the thread has no ready turn diffs and the worktree diff is empty

  @backlog @mobile
  Scenario Outline: Each turn is offered as a source named by its number
    Given "Fix checkout" has a turn whose diff <state>
    When the user opens the choice of diffs to review
    Then the turn is listed with "<subtitle>"

    Examples:
      | state                   | subtitle        |
      | is ready with 2 files   | 2 files changed |
      | is ready with 1 file    | 1 file changed  |
      | is still being prepared | Diff pending    |
      | could not be made       | Diff error      |

  @backlog @mobile
  Scenario: Turns are offered newest first and the newest is the latest turn
    Given "Fix checkout" has three turns with ready diffs
    When the user opens the choice of diffs to review
    Then the turns are listed from the third to the first
    And "Latest turn" is the third

  @backlog @mobile
  Scenario: Branch changes without a base branch say so
    Given the checkout of "Fix checkout" has no base branch to compare with
    When the user opens the choice of diffs to review
    Then branch changes read "Base branch unavailable"

  @backlog @mobile
  Scenario: The working tree is offered while its changes are still loading
    Given the user opens the thread's review before the working tree has been read
    Then the working tree is offered as the dirty worktree
    And it says it covers tracked, staged and untracked changes

  @backlog @mobile
  Scenario: A diff that could not be loaded names the file and can be retried
    Given the diff of "src/cart.ts" could not be loaded
    When the user reviews the changes
    Then "src/cart.ts" says the diff could not be loaded and to select the file to retry
    When the user selects "src/cart.ts"
    Then the diff of "src/cart.ts" is asked for again

  @backlog @mobile
  Scenario: A file preview that cannot be drawn says so and keeps the counts
    Given the preview of "src/cart.ts" cannot be displayed
    When the user reviews the changes
    Then "src/cart.ts" says its preview could not be displayed
    And its added and removed counts are still shown

  @backlog @mobile
  Scenario Outline: A diff the phone cannot lay out is shown as a raw patch
    Given the diff of the latest turn <problem>
    When the user reviews the latest turn
    Then the raw patch is shown
    And the user is told "<notice>"
    And no changed files list is offered

    Examples:
      | problem                              | notice                                                                          |
      | is in a format the phone cannot read | Unsupported diff format. Showing raw patch.                                     |
      | cannot be parsed                     | Failed to parse patch. Showing raw patch.                                       |
      | was cut short before it could parse  | Diff was truncated before it could be parsed completely. Showing the raw excerpt. |

  @backlog @mobile
  Scenario: Pulling down on a diff reads it again
    Given the user is reviewing the working tree
    When the user pulls down on the diff
    Then the phone asks "My MacBook" for the working tree changes again

  @backlog @mobile
  Scenario: Android offers to refresh the current diff from the menu
    Given the user is on an Android phone
    And the user is reviewing the working tree
    When the user opens the review menu
    Then the user is offered to refresh the current diff

  @backlog @mobile
  Scenario: The review header summarises the diff and the pending comments
    Given the diff adds 12 lines and removes 4
    And the draft for "Fix checkout" carries two review comments
    When the user looks at the review header
    Then the header shows 12 added, 4 removed and "2 comments"

  @backlog @mobile
  Scenario: A review that cannot be loaded says why above whatever is cached
    Given the user reviewed the latest turn earlier
    And reading the diff now fails with a reason
    When the user reviews the latest turn
    Then the user is told the review is unavailable and why
    And the earlier diff is still shown below

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
  Scenario: A diff too large to keep does not push the kept diffs out
    Given the user has reviewed three diffs that the phone kept
    When the user reviews a diff too large for the phone to keep
    Then the large diff is shown while it is open
    And the three earlier diffs are still kept

  @backlog @mobile
  Scenario: Nearby diffs are prepared before the user opens them
    Given the user is reviewing the latest turn
    When the user opens the choice of diffs
    Then the diffs next to the open one are already prepared
    And choosing one shows it without waiting

  @backlog @mobile
  Scenario: Offline the choice of diffs still offers the diffs seen before
    Given the user reviewed only the latest turn earlier
    And "My MacBook" is unreachable
    When the user opens the review of the working tree
    Then the user is told the working tree will load when the connection returns
    And the user can still choose the latest turn

  @backlog @mobile
  Scenario: Switching the diff source clears the file being looked at
    Given the user selected "src/price.ts" in the changed files list of the latest turn
    When the user switches to the working tree
    Then no file is selected in the changed files list

  @backlog @mobile
  Scenario: A file that is no longer in the diff is no longer selected
    Given the user selected "src/price.ts" in the changed files list
    When the diff is read again and no longer contains "src/price.ts"
    Then no file is selected in the changed files list

  @backlog @mobile
  Scenario: Wide diffs scroll sideways without breaking the back swipe
    Given the user is reviewing a file with very long lines scrolled to their start
    When the user swipes from the leading edge
    Then the user goes back to the thread

  @backlog @mobile
  Scenario: Each file in a diff scrolls sideways on its own
    Given the diff shows "src/cart.ts" and "src/price.ts" with very long lines
    When the user scrolls the lines of "src/cart.ts" sideways
    Then the lines of "src/price.ts" stay where they were

  @backlog @mobile
  Scenario: The header of the file being read stays at the top of the diff
    Given the diff of "src/cart.ts" is longer than the screen
    When the user scrolls down through "src/cart.ts"
    Then the header of "src/cart.ts" stays at the top
    And the header of "src/price.ts" replaces it when the user reaches that file

  @backlog @mobile
  Scenario: A renamed file's header shows where it came from
    Given the agent renamed "src/cart.ts" to "src/basket.ts"
    When the user reviews the changes
    Then the header reads "src/cart.ts" to "src/basket.ts"

  @backlog @mobile
  Scenario: A long file path in a header scrolls instead of being cut off
    Given the path of a changed file is wider than the screen
    When the user looks at its header
    Then the path fades out at the edge it continues past
    When the user drags the path sideways
    Then the rest of the path is shown

  @backlog @mobile
  Scenario: Collapsing a file keeps its header where the user is looking
    Given the user has scrolled into the middle of "src/cart.ts"
    When the user collapses "src/cart.ts"
    Then the header of "src/cart.ts" is still on screen

  @backlog @mobile
  Scenario: Deleted lines are marked in a way that does not rely on colour
    Given a line was deleted from "src/cart.ts"
    When the user reviews the changes
    Then the deleted line is marked with stripes as well as its colour

  @backlog @mobile
  Scenario: A comment inside a diff can be collapsed to its range
    Given "src/cart.ts" has a comment on lines 10 to 14
    When the user reviews the changes
    Then the comment is shown in the diff under those lines
    When the user collapses the comment
    Then only "Comment on lines 10-14" is shown
    When the user expands the comment
    Then the comment text is shown again

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
  Scenario: A git action in progress is shown over the thread until it ends
    Given the user started committing the changes of the thread
    Then a notice over the thread says the commit is in progress
    When the commit finishes
    Then the notice says what was done
    And the user can dismiss it

  @backlog @mobile
  Scenario: A finished git action that made a pull request leads to it
    Given the user opened a pull request from the thread
    When the notice that the pull request was opened is tapped
    Then the pull request opens in the browser

  @backlog @mobile
  Scenario: A running git action shows its latest output or how long it has run
    Given a git action of the thread is running
    Then the notice shows the latest line the action printed
    When the action has printed nothing for a while
    Then the notice says how many seconds it has been running

  @backlog @mobile
  Scenario: A finished git action's notice goes away by itself
    Given a git action of the thread finished
    When 5 seconds pass
    Then the notice is gone

  @backlog @mobile
  Scenario Outline: Pulling the latest changes says what it did
    Given the thread's branch "feature/cart" <state>
    When the user pulls the latest changes
    Then the notice reads "<notice>"
    And the status of the checkout is read again

    Examples:
      | state                       | notice                         |
      | is already up to date       | Already up to date             |
      | was behind its remote       | Pulled latest on feature/cart  |

  @backlog @mobile
  Scenario: A new worktree made from the phone becomes the thread's checkout
    When the user creates a worktree on the branch "fix-cart-total" from "main"
    Then the thread works in the new worktree on "fix-cart-total"
    And the git sheet shows the new worktree's folder

  @backlog @mobile
  Scenario Outline: A git change of the checkout that the environment refuses says so and changes nothing
    Given "My MacBook" refuses to <change> with "local changes would be overwritten"
    When the user asks to <change>
    Then a notice over the thread says the git action failed and why
    And the thread stays on the branch it was on

    Examples:
      | change                          |
      | switch to another branch        |
      | create a branch                 |
      | pull the latest changes         |

  @backlog @mobile
  Scenario: A failed git action is reported over the thread until dismissed
    Given committing the changes of the thread fails
    Then a notice over the thread says the git action failed and why
    When the user dismisses the notice
    Then the notice is gone

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

  @backlog @mobile
  Scenario: A branch checked out in another worktree cannot be switched to from the branch list
    Given "feature/search" is checked out in another worktree
    When the user opens the branch list
    Then "feature/search" cannot be chosen

  @backlog @mobile
  Scenario Outline: Each branch in the branch list says where it stands
    Given the thread's checkout is on "feature/cart" and the default branch is "main"
    When the user opens the branch list
    Then "<branch>" is described as "<description>"

    Examples:
      | branch        | description                       |
      | feature/cart  | Checked out in this thread        |
      | main          | Default branch                    |
      | feature/misc  | Local branch                      |

  @backlog @mobile
  Scenario: A branch list that is still loading or empty says so
    When the user opens the branch list before the branches have arrived
    Then the list says the branches are loading
    When the repository turns out to have no local branches
    Then the list says no local branches were found

  @backlog @mobile
  Scenario: A new branch made from the phone is checked out at once
    When the user creates the branch "fix cart total" from the branch list
    Then the thread's checkout is on "fix-cart-total"
    And the branch list closes

  @backlog @mobile
  Scenario: A new branch needs a name
    When the user opens the new branch form with the name empty
    Then creating the branch is not offered

  @backlog @mobile
  Scenario Outline: A new worktree starts from the branch the user is on
    Given the thread's checkout is <state>
    When the user opens the new worktree form
    Then the base branch is "<base>"

    Examples:
      | state                  | base         |
      | on "feature/cart"      | feature/cart |
      | on a detached commit   | main         |

  @backlog @mobile
  Scenario Outline: The git menu line follows the state of the checkout
    Given the thread's checkout is <state>
    When the user opens the git menu of the thread
    Then the menu says "<line>"

    Examples:
      | state                          | line                |
      | still being checked            | Checking status     |
      | not a git repository           | Not a repo          |
      | clean                          | Clean               |
      | 3 files changed                | 3 changed           |
      | 2 commits ahead of its remote  | 2 ahead             |
      | 1 commit behind its remote     | 1 behind            |
      | on a branch with pull request 12 | PR #12            |

  @backlog @mobile
  Scenario: A long branch name is shortened in the middle in the git menu
    Given the thread's branch is "feature/very-long-name-for-the-cart-total-rounding-fix"
    When the user opens the git menu of the thread
    Then the branch is shown shortened with its start and its end

  @backlog @mobile
  Scenario: A folder that is not a git repository offers no git actions
    Given the thread's workspace is not a git repository
    When the user opens the git menu of the thread
    Then the menu says git is unavailable because the workspace is not a git repository
    And reviewing changes is not offered

  @backlog @mobile
  Scenario: Pulling the latest changes is listed when the branch is behind its remote
    Given the thread's branch is 2 commits behind its remote
    When the user opens the git sheet
    Then pulling the latest changes is listed with the number of commits behind

  @backlog @mobile
  Scenario: Pulling the latest changes is not listed when the branch is not behind
    Given the thread's branch is not behind its remote
    When the user opens the git sheet
    Then pulling the latest changes is not listed

  @backlog @mobile
  Scenario: The git sheet shows the checkout's worktree folder
    Given the thread works in a worktree
    When the user opens the git sheet
    Then the folder of the worktree is shown

  @backlog @mobile
  Scenario: The git sheet refreshes the status when it opens and when pulled down
    Given the thread has uncommitted changes the phone has not seen yet
    When the user opens the git sheet
    Then the status shows the changes without the user asking
    When the user pulls the sheet down
    Then the status is refreshed again

  @backlog @mobile
  Scenario: Reviewing changes from the git sheet leaves a way straight back to the thread
    Given the user opened the git sheet over the thread
    When the user chooses to review changes
    Then the review opens in place of the git sheet
    When the user goes back
    Then the thread is shown

  @backlog @mobile
  Scenario: The user merges a thread's work back to its source from the thread
    Given "Fix checkout" is a fork whose work can be merged back to its source
    When the user chooses to merge back to the source
    Then the work of "Fix checkout" is merged back to its source thread

  @backlog @mobile
  Scenario: Merging back is offered only where it can happen
    Given "Fix checkout" is not a fork
    Then merging back to a source is not offered

  @backlog @mobile
  Scenario: The commit form lists the first changed files and counts the rest
    Given the thread has 5 changed files
    When the user opens the commit form
    Then the first 3 files are listed with their added and removed lines
    And the form says 2 more files are included
    And the form says 5 files are selected

  @backlog @mobile
  Scenario: A file can be left out of a commit and put back
    Given the commit form lists "src/cart.ts" and "src/price.ts"
    When the user chooses to edit the file selection
    And the user leaves out "src/price.ts"
    Then "src/price.ts" is marked as excluded from this commit
    And the form says one file is selected
    When the user resets the selection
    Then both files are selected again

  @backlog @mobile
  Scenario: Only the files the user kept are committed
    Given the user left "src/price.ts" out of the commit
    When the user commits
    Then only "src/cart.ts" is committed

  @backlog @mobile
  Scenario: Committing needs at least one selected file
    Given the user left every changed file out of the commit
    Then committing is not offered
    And committing on a new branch is not offered

  @backlog @mobile
  Scenario: A thread with nothing changed has nothing to commit
    Given the thread has no changed files
    When the user opens the commit form
    Then the form says no changed files are available to commit

  @backlog @mobile
  Scenario: The commit form warns when the thread is on the default branch
    Given the thread's checkout is on the default branch
    When the user opens the commit form
    Then the form warns that this is the default branch

  @backlog @mobile
  Scenario: Pushing from the default branch can move the commits to a new branch first
    Given the thread is on the default branch with commits not yet pushed
    When the user chooses to push
    And the user is asked how to continue and chooses a new branch
    Then a new branch is made from the commits
    And the push goes on from that branch
