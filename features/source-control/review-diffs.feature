# Sources:
#   packages/contracts/src/review.ts (ReviewDiffPreviewInput, ReviewDiffPreviewResult, ReviewDiffFileContentsInput)
#   packages/contracts/src/rpc.ts (review.getDiffPreview, review.getDiffFileContents)
#   apps/server-ex/lib/hal_c2/review.ex
#   apps/web/src/components/DiffPanel.tsx
#   apps/web/src/components/DiffPanelShell.tsx
#   apps/web/src/components/DiffFilePathCopyButton.tsx
#   apps/web/src/components/diffs/DiffFileTree.tsx
#   apps/web/src/components/diffs/DiffCommentAnnotation.tsx
#   apps/web/src/components/diffs/StyledDiffCodeView.tsx
#   apps/web/src/components/diffs/useReviewFilePatches.ts
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

  @desktop @mobile @tui @backlog-mobile @backlog-tui
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

  @backlog @desktop @mobile @tui
  Scenario: Commenting on lines adds review context to the composer
    When the user comments "Use the tax table" on lines 10 to 12 of "src/cart.ts"
    Then the composer carries that comment with the file and line range

  @backlog @desktop
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
