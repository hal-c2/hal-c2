# Sources:
#   packages/contracts/src/review.ts (ReviewDiffPreviewInput, ReviewDiffPreviewResult, ReviewDiffFileContentsInput)
#   packages/contracts/src/rpc.ts (review.getDiffPreview, review.getDiffFileContents)
#   apps/server-ex/lib/hal_c2/review.ex
#   apps/server/src/review/ReviewService.ts (workspace-bound cwd, VCS support)
#   apps/server/src/vcs/GitVcsDriverCore.ts (getReviewDiffPreview, getReviewDiffFileContents)
#   apps/web/src/components/DiffPanel.tsx
#   apps/web/src/components/DiffPanelShell.tsx
#   apps/web/src/components/DiffFilePathCopyButton.tsx
#   apps/web/src/components/DiffWorkerPoolProvider.tsx (highlighting worker fallback)
#   apps/web/src/diffPanelStore.ts (per-thread diff scope and base)
#   apps/web/src/diffFileActions.ts, apps/web/src/fileContextMenu.ts (file actions on a diff file)
#   apps/web/src/reviewCommentContext.ts (review comment context sent with the message)
#   apps/web/src/components/diffs/commentSubmitShortcut.ts
#   apps/web/src/components/diffs/diffFileTree.logic.ts
#   apps/web/src/components/diffs/DiffFileTree.tsx
#   apps/web/src/components/diffs/DiffCommentAnnotation.tsx
#   apps/web/src/components/diffs/StyledDiffCodeView.tsx
#   apps/web/src/components/diffs/useReviewFilePatches.ts
#   packages/client-runtime/src/state/review.ts (a file patch whose source is gone: "Diff no longer available")
#   apps/web/src/lib/baseRefChoices.ts (local and remote refs merged into one base choice)
#   apps/web/src/components/diffs/DiffFileStatus.tsx (partial preview mark, retry loading)
#   apps/tui/src/components/DiffViewer.tsx
#   apps/tui/src/diffSplit.ts
#   apps/tui/src/features.backlog.test.ts (review-workspace)
#   apps/desktop-qt/qml/HalC2/Bricks/RightPanel.qml (Diff)

Feature: Reviewing working tree and branch changes
  Beside a thread the user reviews what changed in the checkout, either uncommitted work
  or the whole branch against its base, file by file.

  Background:
    Given a connected environment with a thread in the git project "shop" on the branch "feature/tax"

  @mc
  Scenario: The working tree diff includes new files
    Given the user changed "src/cart.ts" and created the untracked "src/tax.ts"
    When the user reviews the working tree
    Then both files are in the diff with their line counts

  @mc
  Scenario: Reviewing leaves the user's staging area alone
    Given the user staged "src/cart.ts" and left "src/tax.ts" untracked
    When the user reviews the working tree
    Then "src/cart.ts" is still the only staged file afterwards

  @mc
  Scenario: Reviewing the branch against its base
    Given "feature/tax" has 3 commits on top of "main"
    When the user reviews the branch against "main"
    Then the diff shows every change the 3 commits made

  @mc
  Scenario: Whitespace changes can be hidden
    Given the only change in "src/cart.ts" is re-indentation
    When the user reviews the working tree hiding whitespace changes
    Then "src/cart.ts" shows no changed lines

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (getReviewDiffPreview: PATCH_RENDER_PREFIX_ARGS)
  @mc @backlog
  Scenario: A repository set to show diffs without path prefixes still reviews correctly
    Given the repository of "shop" is configured to show diffs without path prefixes
    And "src/cart.ts" has an uncommitted change
    When the user reviews the working tree
    Then "src/cart.ts" is shown as one file with its change

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (getReviewDiffPreview: unborn HEAD)
  @mc @backlog
  Scenario: A repository with no commits reviews everything as added
    Given the project "notes" is a git repository with no commits
    And "notes" holds a staged "a.txt" and an untracked "b.txt"
    When the user reviews the working tree of "notes"
    Then "a.txt" and "b.txt" are both shown as new files
    And the branch comparison has no files

  @mc
  Scenario: A very large diff is cut short but keeps every file's counts
    Given the working tree changes 2000 files
    When the user reviews the working tree
    Then the diff says it was truncated
    And the line counts of every changed file are still reported

  @mc
  Scenario Outline: Expanding a file shows both sides as they fit its change
    Given "<file>" was <change>
    When the user expands "<file>"
    Then <sides>

    Examples:
      | file        | change                  | sides                                         |
      | src/cart.ts | changed                 | the old and new contents are shown            |
      | src/tax.ts  | added                   | only the new contents are shown               |
      | src/old.ts  | deleted                 | only the old contents are shown               |
      | src/pay.ts  | renamed without changes | the contents are shown once under both names  |
      | src/fee.ts  | renamed and changed     | the old and new contents are shown            |

  @mc
  Scenario: A binary file cannot be expanded
    Given "logo.png" changed
    When the user expands "logo.png"
    Then the user is told the file cannot be shown

  @mc
  Scenario: Expanding a branch file needs both refs
    When the user expands a file of the branch review without naming the base
    Then the user is told "Branch diff file expansion requires both base and head refs."

  @mc
  Scenario: Only folders inside the MC's projects can be reviewed
    When a client asks to review "/etc"
    Then the request is refused with "Review cwd must be inside one of this MC's projects."

  @tui
  Scenario: Each file is shown with its own highlighting
    Given the diff changes "src/cart.ts" and "README.md"
    When the user opens the diff in the terminal client
    Then each file is shown on its own with the highlighting of its language

  @tui
  Scenario: Switching between stacked and split views
    Given the diff is shown stacked in the terminal client
    When the user switches to the split view
    Then the old and new lines are shown side by side

  @tui
  Scenario: Switching back to the stacked view
    Given the diff is shown split in the terminal client
    When the user switches to the stacked view
    Then the old and new lines are shown one above the other

  @desktop @mobile @backlog-mobile
  Scenario: Switching between stacked and split views on the desktop and phone
    When the user switches the diff to the split view
    Then the old and new lines are shown side by side

  @desktop @mobile @tui @backlog-mobile
  Scenario: Choosing what to compare against
    When the user compares the branch against "origin/main" instead of "main"
    Then the diff shows the changes against "origin/main"

  @desktop
  Scenario: Browsing the changed files as a tree
    When the user shows the file tree of the diff
    Then the changed files are listed by folder
    And choosing a file jumps to it

  @desktop
  Scenario: Collapsing and expanding every file
    When the user collapses all files and then expands all files
    Then every file is shown open again

  @desktop
  Scenario: Wrapping long lines
    When the user turns on line wrapping in the diff
    Then long lines wrap instead of scrolling sideways

  @desktop @mobile @tui @backlog-mobile
  Scenario: Commenting on lines adds review context to the composer
    When the user comments "Use the tax table" on lines 10 to 12 of "src/cart.ts"
    Then the composer carries that comment with the file and line range

  @desktop
  Scenario: Removing a line comment before sending
    Given the user commented on lines 10 to 12 of "src/cart.ts"
    When the user deletes that comment
    Then the composer no longer carries it

  @desktop
  Scenario: Opening a diff file in the editor
    When the user opens "src/cart.ts" from the diff
    Then the file opens in the user's editor

  @desktop
  Scenario: Refreshing the diff by hand
    When the user refreshes the diff
    Then the diff shows the checkout as it is now

  @backlog @desktop
  Scenario: The open diff follows the checkout without being refreshed
    Given the user is reviewing the working tree
    When the agent changes "src/cart.ts"
    Then the diff shows the new changes without the user refreshing
    And coming back to the window after working elsewhere shows the checkout as it is now

  @backlog @desktop
  Scenario: The branch diff compares against the branch's own base unless another is chosen
    Given the branch "feature/tax" was started from "main"
    When the user reviews the branch changes
    Then the diff compares against "main" and the choice of base reads "Automatic"
    When the user picks "origin/main" as the base
    Then the diff compares against "origin/main"
    When the user picks "Automatic" again
    Then the diff compares against "main"

  @backlog @desktop
  Scenario: A base that exists only on the remote is offered and marked
    Given "origin/release" exists on the remote and has no local branch
    When the user searches the bases to compare against for "release"
    Then "origin/release" is offered and marked as remote only
    And a search that matches nothing says no refs match

  # Legacy: apps/web/src/lib/baseRefChoices.ts (buildBaseRefChoices, filterBaseRefChoices)
  @backlog @desktop
  Scenario: A branch that exists locally and on the remote is offered once
    Given "release" exists locally and as "origin/release"
    When the user opens the bases to compare against
    Then "release" is offered once
    And searching for "origin/release" finds that same entry
    And choosing it compares against the local "release"

  # Legacy: apps/web/src/components/DiffPanel.tsx (baseRefChoices excludes the head ref)
  @backlog @desktop
  Scenario: The branch under review is not offered as its own base
    Given the user is reviewing the changes of "feature/tax"
    When the user opens the bases to compare against
    Then "feature/tax" is not among them

  @backlog @desktop
  Scenario: A diff too large to load whole loads each file's changes when it is opened
    Given the changes are too large for the diff to carry every file's patch
    When the user reviews the changes
    Then the diff says it is incomplete while its totals still cover every change
    And a file's changes are loaded when the user opens that file
    And a file whose changes cannot be loaded says no patch is available for it

  @backlog @desktop
  Scenario: A file too large to show in full is marked as a partial preview
    Given "src/cart.ts" has changes too large to show in full
    When the user opens "src/cart.ts" in the diff
    Then the file is marked as a partial preview
    And the mark explains that the file is too large to show in full and that the counts include all changes

  @backlog @desktop
  Scenario: A file whose changes failed to load can be loaded again
    Given loading the changes of "src/cart.ts" failed
    When the user opens "src/cart.ts" in the diff
    Then the file offers to retry loading the diff
    When the user retries and the environment answers
    Then the changes of "src/cart.ts" are shown

  @backlog @desktop
  Scenario: A file's changes that the checkout no longer has say the diff is gone
    Given the user opened a diff and the checkout was changed so that this diff no longer exists
    When the user opens "src/cart.ts" in the diff
    Then the file says "Diff no longer available. Refresh the comparison."
    When the user refreshes the diff
    Then the files that still differ are listed again

  @backlog @desktop
  Scenario Outline: A diff with nothing to show says why
    When the user reviews <selection>
    Then the diff says "<message>"

    Examples:
      | selection                              | message                               |
      | a selection that changed nothing       | No net changes in this selection.     |
      | a selection the MC has no patch for    | No patch available for this selection. |

  @backlog @desktop
  Scenario: Each thread keeps its own choice of what to review
    Given the user reviews "Turn 2" in the thread "Tax" and the branch against "origin/main" in the thread "Fees"
    When the user switches between "Tax" and "Fees"
    Then each thread shows its own selection with its own base
    And a thread that was never reviewed opens on the working tree without needing git status

  @backlog @desktop
  Scenario: A turn that no longer exists falls back to the latest turn
    Given the user is reviewing "Turn 3" of the thread
    When the thread is rolled back to turn 2
    Then the diff shows the latest turn

  @backlog @desktop
  Scenario: Choosing a collapsed file in the tree opens it and scrolls to it, again each time
    Given "src/cart.ts" is collapsed in the diff
    When the user chooses "src/cart.ts" in the file tree
    Then "src/cart.ts" opens and is scrolled to
    When the user scrolls away and chooses "src/cart.ts" again
    Then "src/cart.ts" is scrolled to again

  @backlog @desktop
  Scenario: A refreshed diff keeps the folders of the tree the user opened and closed
    Given the user closed the folder "src/lib" in the diff's file tree
    When a refresh brings a new changed file in "src/lib"
    Then "src/lib" stays closed
    And the new file is listed in it

  @backlog @desktop
  Scenario: The changed files are listed in the order the diff shows them
    Given the diff changes "src/b.ts" before "docs/a.md" before "src/a.ts"
    When the user shows the file tree of the diff
    Then each folder sits where its first changed file is

  @backlog @desktop
  Scenario: A file replaced by a link of the same name is listed once as modified
    Given "src/cart.ts" was a regular file and is now a symbolic link
    When the user shows the file tree of the diff
    Then "src/cart.ts" is listed once as modified

  @backlog @desktop
  Scenario: A file's path can be copied from the diff
    When the user copies the path of "src/cart.ts" from its heading in the diff
    Then "src/cart.ts" is on the clipboard
    And the user is told it was copied

  @backlog @desktop
  Scenario Outline: A diff file offers the file actions the environment has
    Given the environment <capabilities>
    When the user opens the menu of "src/cart.ts" in the diff
    Then <offered>

    Examples:
      | capabilities                                         | offered                                                   |
      | has a file manager and the editors "VS Code", "Zed"  | open, reveal in the file manager and open with either editor |
      | has no file manager                                  | only opening with the editors is offered                  |
      | has nothing that can open files                      | no menu is shown                                          |

  @backlog @desktop
  Scenario: A changed file outside the thread's folder has no file actions
    Given the thread works in "packages/web" of the repository
    When the user opens "packages/api/server.ts" from the diff
    Then nothing is opened because the file is not in the thread's folder
    And "packages/web/src/app.ts" opens as "src/app.ts"

  @backlog @desktop
  Scenario: A diff is still shown when syntax highlighting cannot start
    Given the highlighter cannot be started
    When the user reviews the working tree
    Then the changes are shown without syntax colours

  @backlog @desktop
  Scenario: A review comment is sent with a pasted code fence intact
    Given the user comments with a code block fenced by three backticks on lines 10 to 12 of "src/cart.ts"
    When the message is sent
    Then the provider receives the comment and the quoted lines with the code kept in one piece
    And the quoted lines carry the language of "src/cart.ts"

  @backlog @desktop
  Scenario: A line comment is added from the keyboard
    Given the user is writing the comment "Use the tax table" on "src/cart.ts" lines 10 to 12
    When the user presses mod+enter
    Then the comment is added to the composer

  @backlog @desktop
  Scenario: An empty line comment is not added from the keyboard
    Given the user is writing an empty comment on "src/cart.ts" lines 10 to 12
    When the user presses mod+enter
    Then nothing is added to the composer

  @backlog @mc
  Scenario: A folder under no version control reviews as nothing to compare
    Given the thread's folder is not under version control
    When the user reviews the working tree
    Then the review lists no sources to compare
    And no error is shown

  @backlog @mc
  Scenario: A folder under a version control the MC cannot preview says so
    Given the thread's folder is managed by a version control other than git that cannot preview changes
    When the user reviews the working tree
    Then the user is told "The <kind> VCS driver does not support review diff previews." with the version control's own name

  @backlog @mc
  Scenario: Expanding unchanged lines needs a git repository
    Given the thread's folder is not a git repository
    When the user expands the unchanged lines of "src/cart.ts"
    Then the user is told "Unchanged diff expansion currently requires a Git repository."

  @backlog @mc
  Scenario Outline: A thread's own worktree can be reviewed and nothing outside the projects can
    When a client asks <request> for a folder <place>
    Then <outcome>

    Examples:
      | request                    | place                                          | outcome                                                                       |
      | for a review               | inside the MC's worktrees folder               | the review is returned                                                        |
      | for the contents of a file | inside the MC's worktrees folder               | the contents are returned                                                     |
      | for the contents of a file | outside the MC's projects and worktrees        | it is refused with "Review cwd must be inside one of this MC's projects."     |
      | for a review               | reached through a link out of the MC's projects | it is refused with "Review cwd must be inside one of this MC's projects."    |
