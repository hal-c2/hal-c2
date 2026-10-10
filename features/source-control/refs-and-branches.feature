# Sources:
#   packages/contracts/src/vcs.ts (VcsListRefsInput, VcsListRefsResult, VcsSwitchRefInput, VcsCreateRefInput)
#   packages/contracts/src/rpc.ts (vcs.listRefs, vcs.switchRef, vcs.createRef)
#   apps/server-ex/lib/hal_c2/vcs.ex (list_refs, switch_ref, create_ref)
#   apps/web/src/components/BranchToolbar.tsx
#   apps/web/src/components/BranchToolbar.logic.ts
#   apps/web/src/components/BranchToolbarBranchSelector.tsx
#   apps/web/src/components/BranchPicker.tsx
#   apps/web/src/hooks/useThreadBranchSelection.ts (a switch or creation that fails reports and keeps the branch)
#   apps/web/src/components/WorktreeBaseBranchPicker.tsx
#   apps/web/src/components/BranchToolbar.logic.ts (sanitizeNewRefName, shouldIncludeBranchPickerItem, resolveBranchTriggerLabel, resolveLocalCheckoutBranchMismatch)
#   apps/web/src/components/ChatView.tsx, ChatView.logic.ts (branch changed notice, restore branch)
#   apps/web/src/components/Sidebar.tsx (row text when another branch is checked out)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (branch picker)
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (branch line)
#   packages/contracts/src/shell.ts (workspace.branch.search, workspace.branch.select, workspace.branch.create)
#   apps/tui/src/features.backlog.test.ts (branch-worktree-management)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the ref list, switching and creating)
#   apps/server/src/vcs/GitVcsDriverCore.ts (listRefs snapshot cache and refresh limits, unborn and missing folders)

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

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (listRefs: snapshot cache, epoch bumps)
  @mc @backlog
  Scenario: Paging through a long branch list does not read the repository again
    Given "shop" has 400 branches
    When a client reads every page of the branch list
    Then the repository's refs are read once for all the pages

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (withListRefsInvalidation)
  @mc @backlog
  Scenario Outline: A branch change made through HAL-C2 shows in the next list
    Given the branch list of "shop" was read a moment ago
    When the user <change>
    And the branch list is read again
    Then the list shows the change

    Examples:
      | change                                |
      | creates the branch "feature/new"      |
      | switches to "feature/old"             |
      | removes a worktree and its branch     |
      | renames the temporary branch of a new worktree |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (LIST_REFS_REFRESH_COALESCE_TTL, LIST_REFS_REFRESH_FAILURE_COOLDOWN)
  @mc @backlog
  Scenario: Asking for a fresh branch list again and again does not hammer the repository
    Given clients ask for a fresh branch list of "shop" several times within five seconds
    Then the repository's refs are read once
    And after a read that failed the next fresh read is not attempted for half a minute

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (listRefs: isRepo false)
  @mc @backlog
  Scenario Outline: A folder with no repository has no branches and says so
    Given <situation>
    When a client lists the branches of "notes"
    Then no branches are returned
    And the result says it is not a repository

    Examples:
      | situation                                |
      | "notes" is a folder that is not a repository |
      | the folder "notes" was removed from disk |

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

  @backlog @desktop
  Scenario: A new branch that cannot be created keeps the branch and says why
    Given the MC cannot create the branch: "A branch named 'main' already exists"
    When the user creates the branch "main" for the thread and switches to it
    Then the user sees an "error" toast "Failed to create and switch ref." saying "A branch named 'main' already exists"
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

  @backlog @desktop
  Scenario Outline: A new branch name made of several words is made with dashes
    Given the user searched the branch list for "<typed>"
    When the user creates it
    Then the branch "<created>" is created

    Examples:
      | typed            | created        |
      | new branch       | new-branch     |
      | fix  the   cart  | fix-the-cart   |
      | Feature/Pay      | Feature/Pay    |

  @backlog @desktop
  Scenario: Typing a name with spaces still finds the branch that has dashes
    Given the project has the branch "new-branch"
    When the user searched the branch list for "new branch"
    Then "new-branch" is listed
    And no entry offers to create "new-branch" again

  @backlog @desktop
  Scenario Outline: The entry to create a branch comes and goes with the search text
    Given the user is <picking>
    When the user searched the branch list for "<text>"
    Then creating "<text>" is <offered>

    Examples:
      | picking                                  | text         | offered       |
      | choosing the branch of the checkout      | feature/pay  | offered       |
      | choosing the branch of the checkout      |              | not offered   |
      | choosing the branch of the checkout      | main         | not offered   |
      | choosing the base of a new worktree      | feature/pay  | not offered   |

  @backlog @desktop
  Scenario: A pull request typed in the branch search can be checked out
    Given the project is hosted where pull requests are called "merge requests"
    When the user searched the branch list for "https://gitlab.com/acme/shop/-/merge_requests/42"
    Then the first entry offers to check out merge request 42
    When the user chooses it
    Then the pull request thread dialog opens for merge request 42

  @backlog @desktop
  Scenario: A thread's checkout moved off its branch is called out
    Given the thread last ran on "feature/tax" in the project's folder
    And someone checked out "main" in that folder
    When the user looks at the thread's branch
    Then the thread says the folder is on "main" but the thread last ran on "feature/tax"
    And sending would continue on "main"

  @backlog @desktop
  Scenario: The branch notice appears once the user starts writing
    Given the thread last ran on "feature/tax" and the folder is now on "main"
    When the user has not typed anything yet
    Then no branch notice is shown
    When the user types a message
    Then the notice "Branch changed — was feature/tax" is shown

  @backlog @desktop
  Scenario: The user can put the thread's branch back
    Given the branch notice is shown for "feature/tax"
    When the user restores the branch
    Then the folder is switched to "feature/tax"
    And the notice goes away

  @backlog @desktop
  Scenario Outline: Restoring the thread's branch can fail
    Given the branch notice is shown for "feature/tax"
    And <failure>
    When the user restores the branch
    Then the user sees an "error" toast "<title>"

    Examples:
      | failure                                                  | title                                                |
      | git refuses to switch the folder                         | Failed to switch checkout                            |
      | the folder switched but the thread could not be updated  | Checkout switched, but the thread could not be updated |

  @backlog @desktop
  Scenario: The branch notice can be dismissed
    Given the branch notice is shown for "feature/tax"
    When the user dismisses it
    Then the notice goes away and the message is sent on the folder's current branch

  @backlog @desktop
  Scenario: Putting the thread's branch back asks first when there are uncommitted changes
    Given the branch notice is shown for "feature/tax"
    And the folder has uncommitted changes
    When the user restores the branch
    Then the user is asked "Switch to feature/tax?" and told the changes carry over or block the switch if they conflict
    And the folder is switched only when the user chooses "Switch branch"

  @backlog @desktop
  Scenario: Sending on the folder's branch makes it the thread's branch
    Given the thread last ran on "feature/tax" and the folder is now on "main"
    When the user sends a message without restoring the branch
    Then the thread is recorded on "main"
    And the branch notice is not shown again for "feature/tax"

  @backlog @desktop
  Scenario: A thread in the project's folder says another branch is checked out
    Given the thread last ran on "feature/tax" in the project's folder
    And the folder is now on "main"
    When the user looks at the thread list
    Then the thread's row says the folder is currently checked out on another branch

  @backlog @desktop
  Scenario: A new thread's base ref is labelled as coming from origin when it starts from there
    Given the user chose a new worktree for a new thread based on the local branch "main"
    When the user chooses to start the worktree from origin
    Then the base reads "From origin/main"

  @backlog @desktop
  Scenario: A base that is a remote branch reads as itself
    Given the user chose a new worktree for a new thread based on the remote branch "origin/release"
    Then the base reads "From origin/release"

  @backlog @desktop
  Scenario Outline: The branch list says when it is still loading or has nothing to show
    Given <state>
    When the user opens the branch list
    Then the list says "<message>"

    Examples:
      | state                                      | message               |
      | the refs have not arrived yet              | Loading refs...       |
      | the next page of refs is on its way        | Loading more refs...  |
      | no ref matches the search text             | No refs found.        |

  @backlog @desktop
  Scenario: The base of a new worktree is chosen from a list that behaves like the branch list
    Given the user chose a new worktree for a new thread in "shop" which has 400 refs
    When the user opens the base picker and searches for "release"
    Then only the refs that match are listed
    When the user clears the search
    Then the list says how many of the 400 refs are shown
    And scrolling to the end loads the next page
