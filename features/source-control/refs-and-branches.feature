# Sources:
#   https://github.com/pingdotgg/t3code/pull/27274
#   https://github.com/pingdotgg/t3code/pull/24060
#   https://github.com/pingdotgg/t3code/pull/23764
#   https://github.com/pingdotgg/t3code/pull/23314
#   https://github.com/pingdotgg/t3code/pull/14157
#   https://github.com/pingdotgg/t3code/pull/22807
#   https://github.com/pingdotgg/t3code/pull/22225
#   https://github.com/pingdotgg/t3code/pull/20440
#   https://github.com/pingdotgg/t3code/pull/19315
#   https://github.com/pingdotgg/t3code/pull/23436
#   https://github.com/pingdotgg/t3code/pull/27434
#   https://github.com/pingdotgg/t3code/pull/29908
#   https://github.com/pingdotgg/t3code/pull/31599
#   https://github.com/pingdotgg/t3code/pull/27438
#   https://github.com/pingdotgg/t3code/pull/29161
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

  # Upstream #22807: after a git switch in a terminal, the picker kept the old branch as
  # current, even once that branch was deleted.
  @backlog @mc @shared
  Scenario: Opening the branch list picks up a branch switched outside HAL-C2
    Given the user ran "git switch main" in a terminal of the thread
    When the user opens the branch list
    Then "main" is marked current
    And the thread shows "main" with no ahead or behind counts or pull request left from "feature/tax"

  # Upstream #27438: the MC answered from a two-minute snapshot of the branches, so a branch
  # created or deleted in a terminal or by an agent was missing or still listed.
  @backlog @mc @shared
  Scenario: Opening the branch list shows branches created and deleted outside HAL-C2
    Given the user opened the branch list of "shop" a moment ago
    And the user ran "git branch round-1 && git branch -D feature/old" in a terminal
    When the user opens the branch list again
    Then "round-1" is listed
    And "feature/old" is not

  # Upstream #31599: after an agent or a terminal checked out another branch in a thread's
  # worktree, the sidebar and the thread's details kept showing the generated branch.
  @backlog @mc @shared @priority-high
  Scenario: Every thread in a worktree follows a branch checked out there
    Given the threads "Tax" and "Tax review" share a worktree on "hal-c2/bfc349ae"
    When the agent in "Tax" runs "git switch union" in that worktree
    Then the thread list and the details of both threads show "union"
    And a slower status report of "hal-c2/bfc349ae" does not bring the old branch back
    And a worktree reached through a symlinked path follows the switch too

  # Upstream #31599: detached checkouts and the project folder keep what they showed.
  @backlog @mc
  Scenario: A detached checkout in a worktree leaves its threads' branch
    Given the thread "Tax" is in a worktree on "hal-c2/bfc349ae"
    When a commit is checked out detached in that worktree
    Then "Tax" keeps "hal-c2/bfc349ae" as its branch

  # Upstream #23436: the mobile branch list marked the project folder's branch current for a worktree thread.
  @backlog @mobile @priority-high
  Scenario: A worktree thread's branch list marks the worktree's branch current
    Given the project folder of "shop" is on "main"
    And the thread works in its own worktree on "feature/tax"
    When the user opens the branch list
    Then "feature/tax" is marked current and "main" is not

  # Upstream #22807
  @backlog @mc
  Scenario: Opening the branch list does not fetch from the remote
    When the user opens the branch list
    Then the thread's git status is read from the checkout
    And nothing is fetched and no pull request is looked up

  @mc @desktop
  Scenario: Searching narrows the branch list
    # The scenario needs "feature/old" to exist before it can find it.
    Given "shop" has the branches "main", "feature/tax" and "feature/old"
    When the user searches the branch list for "old"
    Then only "feature/old" is listed

  # Upstream #27434: typing a search highlighted nothing, so Enter closed the picker without
  # choosing and the down arrow skipped the first result.
  @backlog @shared
  Scenario Outline: Enter picks the first result of a branch search
    Given "shop" has the branches "main", "feature/tax" and "feature/old"
    When the user searches the <list> for "feat" and presses Enter
    Then the first branch listed for "feat" is chosen

    Examples:
      | list                         |
      | branch list                  |
      | base picker of a new worktree |

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
  @mc @backlog @priority-low
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

  # Upstream #29161: checking out a pull request left the branch lists already open without its
  # branch, with the old branch still current.
  @backlog @shared
  Scenario: Checking out a pull request refreshes the branch lists already open
    Given the user has the branch list and the base list of a new worktree open in "shop"
    When the user checks out pull request #42 on the branch "fix-tax" in a new worktree
    Then both lists show "fix-tax" with its worktree

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (LIST_REFS_REFRESH_COALESCE_TTL, LIST_REFS_REFRESH_FAILURE_COOLDOWN)
  @mc @backlog @priority-low
  Scenario: Asking for a fresh branch list again and again does not hammer the repository
    Given clients ask for a fresh branch list of "shop" several times within five seconds
    Then the repository's refs are read once
    And after a read that failed the next fresh read is not attempted for half a minute

  # Upstream #23314: a reconnect that replaced the session left the branch list stale until the
  # next connection change.
  @shared @backlog @priority-low
  Scenario: The branch list is read again after a reconnect
    Given the user has the branch list of "shop" open
    And a branch was created on the machine while the client was disconnected
    When the client reconnects
    Then the new branch is listed without the user asking
    And a read that fails while the connection is coming back is retried quietly

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

  # Upstream #19315: "git worktree list -z" needs git 2.36, and older git dropped every path.
  @backlog @mc @priority-low
  Scenario: Worktree paths are found on git older than 2.36
    Given the machine's git is 2.25
    And "feature/old" is checked out in another worktree
    When the user lists branches
    Then "feature/old" is marked with that worktree's path
    And an agent can still launch a thread in that worktree

  # Upstream #14157: with a git folder kept outside the checkout, git listed that folder as the
  # branch's worktree.
  @backlog @mc @priority-low
  Scenario: A repository whose git folder lives elsewhere is not listed as a worktree
    Given "shop" keeps its git folder outside the project folder
    When the user lists branches
    Then the current branch is shown as checked out in the project folder
    And the git folder is not listed as a worktree

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

  # Upstream #20440: remote, ref and path names reach git after "--end-of-options", and a
  # branch name starting with "-" (other than a lone "-") is refused before a checkout or a
  # worktree is made.
  @backlog @mc @priority-high
  Scenario Outline: A branch named like an option is refused before git sees it
    When the user <action> the branch "--upload-pack=touch pwned"
    Then the MC refuses it as a branch name
    And nothing is checked out or created

    Examples:
      | action                 |
      | switches to            |
      | creates a worktree for |

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

  @desktop @mobile @backlog-mobile @priority-low
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

  # Upstream #23764: the phone called a main-checkout thread's own branch "checked out in another worktree".
  @backlog @shared
  Scenario: A thread in the project folder can pick its own folder's branch
    Given a thread works in the project folder, which is on "main"
    And "feature/old" is checked out in another worktree
    When the user lists the thread's branches
    Then "main" is shown as this thread's checkout and can be chosen
    And "feature/old" is shown as checked out elsewhere and cannot be chosen

  # Upstream #29908: in a project that is a subfolder of its repository, picking the checkout's own
  # branch moved the thread to the repository root as a worktree.
  @backlog @shared @priority-high
  Scenario: Picking a branch in a subfolder project keeps the thread in the project folder
    Given the project "app" is the folder "packages/app" inside the repository "shop"
    And a thread of "app" works in the project folder, which is on "main"
    When the user picks "main" from the thread's branches
    Then the thread still works in "packages/app" and not in a worktree
    And its agent and terminal keep running there

  @desktop @mobile @backlog-mobile
  Scenario: The thread's branch follows the checkout
    Given the agent checked out "feature/pay" in the thread's checkout
    When the status updates
    Then the thread's branch reads "feature/pay"

  @backlog @desktop @priority-low
  Scenario Outline: A new branch name made of several words is made with dashes
    Given the user searched the branch list for "<typed>"
    When the user creates it
    Then the branch "<created>" is created

    Examples:
      | typed            | created        |
      | new branch       | new-branch     |
      | fix  the   cart  | fix-the-cart   |
      | Feature/Pay      | Feature/Pay    |

  # Upstream #27274: accented letters were dropped from generated and typed branch names, which
  # split words: "Añadir validación" became "a-adir-validaci-n".
  @backlog @mc @priority-low
  Scenario Outline: A branch name keeps accented letters as their plain letters
    When a branch name is made from "<words>"
    Then the branch is named "<branch>"

    Examples:
      | words                         | branch                        |
      | fix/Añadir validación del café | fix/anadir-validacion-del-cafe |
      | Größe prüfen                  | groe-prufen                   |

  @backlog @desktop @priority-low
  Scenario: Typing a name with spaces still finds the branch that has dashes
    Given the project has the branch "new-branch"
    When the user searched the branch list for "new branch"
    Then "new-branch" is listed
    And no entry offers to create "new-branch" again

  @backlog @desktop @priority-low
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

  @backlog @desktop @priority-low
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

  # Upstream #24060: a restore still running in one thread showed "Restoring..." in the next and moved focus there when it ended.
  @backlog @desktop
  Scenario: Restoring one thread's branch does not hold up another thread
    Given threads "A" and "B" each show the branch notice
    And the user is restoring the branch of "A"
    When the user switches to "B" before the restore finishes
    Then "B" can restore its own branch
    And focus stays where the user is when the restore of "A" finishes

  @backlog @desktop @priority-low
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

  # Upstream #22225: reverted #14883; an agent switching branches in its own worktree is normal
  # work, so worktree threads do not warn. Threads in the project's folder still do (above).
  @backlog @desktop
  Scenario: A worktree thread whose checkout moved to another branch does not warn
    Given a thread in its own worktree last ran on "feature/tax"
    And the agent checked out "feature/other" in that worktree
    When the user looks at the thread list and the thread's branch
    Then the thread does not say another branch is checked out

  @backlog @desktop @priority-low
  Scenario: A new thread's base ref is labelled as coming from origin when it starts from there
    Given the user chose a new worktree for a new thread based on the local branch "main"
    When the user chooses to start the worktree from origin
    Then the base reads "From origin/main"

  @backlog @desktop @priority-low
  Scenario: A base that is a remote branch reads as itself
    Given the user chose a new worktree for a new thread based on the remote branch "origin/release"
    Then the base reads "From origin/release"

  @backlog @desktop @priority-low
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
