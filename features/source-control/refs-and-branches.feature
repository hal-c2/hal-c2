# Sources:
#   packages/contracts/src/vcs.ts (VcsListRefsInput, VcsListRefsResult, VcsSwitchRefInput, VcsCreateRefInput)
#   packages/contracts/src/rpc.ts (vcs.listRefs, vcs.switchRef, vcs.createRef)
#   apps/server-ex/lib/hal_c2/vcs.ex (list_refs, switch_ref, create_ref)
#   apps/web/src/components/BranchToolbar.tsx
#   apps/web/src/components/BranchToolbar.logic.ts
#   apps/web/src/components/BranchToolbarBranchSelector.tsx
#   apps/web/src/components/BranchPicker.tsx
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (branch picker)
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (branch line)
#   packages/contracts/src/shell.ts (workspace.branch.search, workspace.branch.select, workspace.branch.create)
#   apps/tui/src/features.backlog.test.ts (branch-worktree-management)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the ref list, switching and creating)

Feature: Picking, switching and creating branches
  The user moves a thread's checkout between refs, or makes a new one, from the thread
  itself. The list is searchable and puts the likely choices first.

  Background:
    Given a connected environment with a thread in the git project "shop" on the branch "feature/tax"

  @mc @desktop
  Scenario: The current and default branches come first
    Given "shop" has the branches "main", "feature/tax" and "feature/old"
    When the user opens the branch list
    Then "feature/tax" is marked current and listed first
    And "main" is marked default and listed next
    And the other branches follow, most recently committed first

  @mc @desktop
  Scenario: Searching narrows the branch list
    # The scenario needs "feature/old" to exist before it can find it.
    Given "shop" has the branches "main", "feature/tax" and "feature/old"
    When the user searches the branch list for "old"
    Then only "feature/old" is listed

  @desktop
  Scenario: A long list says how much is hidden
    Given "shop" has 400 branches
    When the user opens the branch list
    Then the user is told how many of the 400 refs are shown and to type to narrow them

  @desktop @mobile @backlog-mobile
  Scenario: Scrolling to the end loads more branches
    Given "shop" has 400 branches
    When the user scrolls to the end of the branch list
    Then the next page of branches is loaded

  @mc
  Scenario: Remote branches that mirror a local one are hidden unless asked for
    Given "main" and "origin/main" point at the same place
    When the user lists all refs
    Then "origin/main" is not listed on its own
    But it is listed when the user asks for matching remote refs too

  @mc
  Scenario: A branch checked out in another worktree says where
    Given "feature/old" is checked out in another worktree
    When the user lists branches
    Then "feature/old" is marked with that worktree's path

  @mc @desktop
  Scenario: Switching to a local branch
    When the user switches the thread to "main"
    Then the checkout is on "main"
    And the thread's branch reads "main"

  @mc
  Scenario: Switching to a remote branch makes a tracking branch
    Given "origin/feature/pay" exists and there is no local "feature/pay"
    When the user switches to "origin/feature/pay"
    Then a local "feature/pay" tracking "origin/feature/pay" is checked out

  @mc
  Scenario: A stale ref is never mistaken for a file
    Given a file is named "feature/gone" and the branch "feature/gone" no longer exists
    When the user switches to "feature/gone"
    Then the switch fails and the file is left as it was

  @mc @desktop
  Scenario: Creating a branch from the search text
    Given the user searched the branch list for "feature/pay"
    And no ref matches
    When the user creates it
    Then "feature/pay" is created and the checkout switches to it

  @mc
  Scenario: Creating a branch without switching to it
    When the user creates the branch "spike" without switching
    Then "spike" exists and the checkout stays on "feature/tax"

  @mc
  Scenario: A switch that would lose changes fails and says why
    Given uncommitted changes in "src/cart.ts" conflict with "main"
    When the user switches the thread to "main"
    Then the switch fails with git's explanation
    And the changes in "src/cart.ts" are kept

  @desktop
  Scenario: A switch that fails keeps the branch and says why
    Given the MC cannot switch the checkout: "Your local changes would be overwritten"
    When the user switches the thread to "main"
    Then the user sees an "error" toast "Failed to switch ref." saying "Your local changes would be overwritten"
    And the checkout is on "feature/tax"
    And the thread's branch reads "feature/tax"

  @desktop
  Scenario: The thread list shows each thread's branch
    When the user looks at the thread list
    Then the thread in "shop" shows the branch "feature/tax"

  @desktop @mobile @backlog-mobile
  Scenario: Copying the branch name
    When the user copies the thread's branch name
    Then "feature/tax" is on the clipboard

  @tui
  Scenario: Switching and creating branches from the terminal client
    When the user switches the thread to "main" from the terminal client
    Then the checkout is on "main" and the thread's branch reads "main"

  @backlog @mobile
  Scenario: Switching branches from the phone
    When the user switches the thread to "main" from the phone
    Then the checkout is on "main"

  @desktop @mobile @backlog-mobile
  Scenario: The thread's branch follows the checkout
    Given the agent checked out "feature/pay" in the thread's checkout
    When the status updates
    Then the thread's branch reads "feature/pay"
