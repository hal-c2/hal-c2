# Sources:
#   docs/user/source-control.md (Linked pull requests)
#   packages/contracts/src/git.ts (GitResolvePullRequestInput, GitPreparePullRequestThreadInput, GitPreparePullRequestThreadResult)
#   packages/contracts/src/rpc.ts (git.resolvePullRequest, git.preparePullRequestThread, pullRequests.linkedThreads, pullRequests.preview)
#   packages/contracts/src/orchestrationV2.ts (thread.pull-request.link, thread.pull-request.unlink, thread.pull-request-link.sync, thread.pull-request-synced)
#   apps/server-ex/lib/hal_c2/pull_requests/checkout.ex
#   apps/server-ex/lib/hal_c2/pull_requests/discovery.ex
#   apps/server-ex/lib/hal_c2/pull_requests/sync.ex
#   apps/server-ex/lib/hal_c2/mcp/tools/pull_requests.ex (link_pull_request, unlink_pull_request, list_thread_pull_requests)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.pull-request.link)
#   apps/web/src/components/PullRequestThreadDialog.tsx
#   apps/web/src/components/PullRequestContextDetails.tsx
#   apps/web/src/components/pullRequest/LinkPullRequestDialog.tsx
#   apps/web/src/components/pullRequest/PullRequestLinkPreview.tsx
#   apps/web/src/lib/openPullRequestLink.ts, openPullRequestLink.test.ts (modifier click, lookalike hosts, issue-route numbers)
#   apps/server/src/pullRequest/PullRequestService.ts (preview, previewFields)
#   apps/web/src/components/pullRequest/pullRequestLinkContextMenu.ts
#   apps/web/src/pullRequestReference.ts (pasted references and checkout commands)
#   apps/web/src/components/pullRequest/PullRequestThreadLinks.tsx
#   apps/web/src/components/pullRequest/PullRequestStackPopover.tsx
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (open pull request)
#   apps/desktop-qt/src/native/ThreadPullRequests.cpp (the right panel's Pull requests tab)
#   apps/desktop-qt/qml/HalC2/Bricks/PullRequestsPanel.qml
#   apps/desktop-qt/tests/native/features/PullRequestSteps.cpp
#   apps/web/src/components/pullRequest/ThreadPullRequestsPanel.tsx
#   apps/tui/src/features.backlog.test.ts (pull request checkout)
#   apps/server/src/git/GitManager.ts (preparePullRequestThread, reused worktrees, fork remotes)
#   apps/server/src/vcs/GitVcsDriverCore.ts (refreshCheckedOutBranch, ensureRemote)
#   apps/server/src/sourceControl/gitHubPullRequests.ts, gitLabMergeRequests.ts, bitbucketPullRequests.ts, forgejoPullRequests.ts (cross-repository detection)
#   apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (checkoutChangeRequest, listChangeRequests, createChangeRequest)

Feature: Threads that work on or link pull requests
  A thread can start from a pull request, checked out locally or in its own worktree,
  and any thread can link the pull requests it relates to and keep them current.

  Background:
    Given a connected environment with the GitHub project "acme/shop"

  @mc
  Scenario Outline: A pull request can be named in several ways
    When the user asks to work on the pull request <reference>
    Then pull request 42 of "acme/shop" is resolved with its title, branches and state

    Examples:
      | reference                                 |
      | 42                                        |
      | #42                                       |
      | https://github.com/acme/shop/pull/42      |

  @mc
  Scenario: A pull request that does not exist
    When the user asks to work on the pull request 9999
    Then the user is told the pull request was not found

  @mc
  Scenario: Working on a pull request in the local checkout
    When the user starts a thread on pull request 42 in the local checkout
    Then the project's checkout switches to the pull request's branch
    And the new thread is linked to pull request 42

  @mc
  Scenario: Working on a pull request in its own worktree
    When the user starts a thread on pull request 42 in a new worktree
    Then the pull request's head is fetched into a worktree of its own
    And the new thread works in that worktree

  @mc
  Scenario: A pull request from a fork gets a branch of its own
    Given pull request 42 comes from the fork branch "tax"
    When the user starts a thread on pull request 42 in a new worktree
    Then the worktree is on the branch "hal-c2/pr-42/tax" with no upstream

  # Legacy: apps/server/src/sourceControl/gitHubPullRequests.ts, gitLabMergeRequests.ts, bitbucketPullRequests.ts, forgejoPullRequests.ts (isCrossRepository)
  @backlog @mc
  Scenario Outline: Each host tells a pull request from another repository in its own way
    Given a pull request on <host> where <given>
    When the user starts a thread on it
    Then it is treated as <treated>

    Examples:
      | host      | given                                                                       | treated                      |
      | GitHub    | the host says it comes from another repository                              | from another repository      |
      | GitLab    | the source and target projects have different ids                           | from another repository      |
      | GitLab    | no ids are given and the source and target paths differ only in case        | from the same repository     |
      | GitLab    | no ids are given and the source and target paths differ                     | from another repository      |
      | Bitbucket | the source and destination repositories have different full names           | from another repository      |
      | Forgejo   | the head and base repositories have different full names                    | from another repository      |
      | Forgejo   | the source repository was deleted                                           | from the same repository     |
      | Bitbucket | the source repository was deleted                                           | from the same repository     |

  # Legacy: apps/server/src/sourceControl/GitHubCli.ts (older gh without headRepositoryOwner)
  @backlog @mc
  Scenario: An older GitHub CLI that names only the source repository's owner and name still gives its full name
    Given the GitHub CLI answers with the source repository's name and its owner's login but no full name
    When the user starts a thread on a pull request from that repository
    Then the source repository is taken as "owner/name"

  @mc
  Scenario: An existing worktree for the pull request is reused
    Given a worktree for pull request 42 exists with local commits
    When the user starts a thread on pull request 42 in a new worktree
    Then the existing worktree is reused
    And the user is told the checkout is not on the pull request's head

  @mc
  Scenario: A pull request branch already in the main checkout cannot get a worktree
    Given the main checkout is on pull request 42's branch
    When the user starts a thread on pull request 42 in a new worktree
    Then the user is told to use the local checkout or switch the main checkout off that branch

  @mc
  Scenario: Pull request worktrees do not run the setup script
    Given "acme/shop" has a setup script for new worktrees
    When the user starts a thread on pull request 42 in a new worktree
    Then the setup script does not run

  # Legacy: apps/server/src/git/GitManager.ts (reuseExistingWorktree), GitVcsDriverCore.ts (refreshCheckedOutBranch)
  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/checkout.ex (advance)
  @mc @backlog
  Scenario: A reused pull request worktree that holds nothing of its own follows the pull request
    Given a worktree for pull request 42 exists with no changes or commits of its own
    And the pull request has since received new commits
    When the user starts a thread on pull request 42 in a new worktree
    Then the existing worktree is moved onto the pull request's newest commit
    And the user is not told the checkout is behind

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (refreshCheckedOutBranch: rewritten head)
  @mc @backlog
  Scenario: A pull request that was rewritten is taken by a worktree that holds nothing of its own
    Given a worktree for pull request 42 exists with no changes or commits of its own
    And the pull request's author has since rebased it and pushed over the old commits
    When the user starts a thread on pull request 42 in a new worktree
    Then the existing worktree is moved onto the rewritten head
    And the commit it was on can still be found afterwards

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (refreshCheckedOutBranch), GitManager.ts (reuseExistingWorktree)
  @mc @backlog
  Scenario Outline: A reused pull request worktree is left as it is when moving it could lose work
    Given a worktree for pull request 42 exists and <state>
    When the user starts a thread on pull request 42 in a new worktree
    Then the existing worktree is handed back unchanged
    And the user is told the checkout is not on the pull request's head

    Examples:
      | state                                                                              |
      | it has uncommitted changes and the pull request has new commits                    |
      | it has commits of its own and the pull request was rewritten                       |
      | the host cannot say what the pull request's head is and the branch was cut from another branch |

  # Legacy: apps/server/src/git/GitManager.ts (reuseExistingWorktree: findLocalHeadBranch)
  @mc @backlog
  Scenario: A branch that only shares a fork pull request's branch name is left alone
    Given pull request 42 comes from the fork branch "main"
    And the user's own "main" is checked out in another worktree
    When the user starts a thread on pull request 42 in a new worktree
    Then the user's "main" worktree is not changed
    And the thread is told the checkout is not on the pull request's head

  # Legacy: apps/server/src/git/GitManager.ts (configurePullRequestHeadUpstream, ensureRemote)
  # Uncertain: the scenario "A pull request from a fork gets a branch of its own" says the branch has no upstream
  @mc @backlog
  Scenario: A pull request branch follows the pull request's own branch so a push lands on it
    Given pull request 42 comes from the fork "sam/shop" branch "tax"
    When the user starts a thread on pull request 42 in a new worktree
    Then the checkout gets a remote for "sam/shop" named after its owner
    And the branch follows "tax" on that remote

  # Legacy: apps/server/src/git/GitManager.ts (shouldPreferSshRemote)
  @mc @backlog
  Scenario Outline: A fork is added the way the project's own remote is reached
    Given the project's "origin" is reached over <protocol>
    And pull request 42 comes from the fork "sam/shop"
    When the user starts a thread on pull request 42 in a new worktree
    Then the fork's remote is added with its <protocol> address

    Examples:
      | protocol |
      | ssh      |
      | https    |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (ensureRemote)
  @mc @backlog
  Scenario: A fork the checkout already has a remote for is not added a second time
    Given the checkout already has a remote "sam-fork" for the address of "sam/shop"
    When the user starts a thread on pull request 42 from "sam/shop" in a new worktree
    Then "sam-fork" is used
    And no further remote is added

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (ensureRemote: preferredName collisions)
  @mc @backlog
  Scenario: A remote already named after the fork's owner but pointing elsewhere gets a numbered name
    Given the checkout has a remote "sam" that points at another repository
    When the user starts a thread on pull request 42 from "sam/shop" in a new worktree
    Then the fork is added as the remote "sam-1"
    And the existing "sam" remote is not changed

  # Legacy: apps/server/src/git/GitManager.ts (materializePullRequestHeadBranch)
  @mc @backlog
  Scenario: A fork that cannot be fetched falls back to the pull request's own ref
    Given pull request 42 comes from the fork "sam/shop" and the fork cannot be fetched from
    When the user starts a thread on pull request 42 in a new worktree
    Then the pull request's head is fetched from the host's own pull request ref instead
    And the thread starts in a worktree on it

  # Legacy: apps/server/src/git/GitManager.ts (GitPullRequestMaterializationError)
  @mc @backlog
  Scenario: A pull request that cannot be fetched either way names both failures
    Given pull request 42 comes from the fork "sam/shop"
    And neither the fork nor the host's pull request ref can be fetched
    When the user starts a thread on pull request 42 in a new worktree
    Then the thread is not prepared
    And the user is told that both fetches failed for pull request 42

  # Legacy: apps/server/src/git/GitManager.ts (configurePullRequestHeadUpstream: Effect.catch logs)
  @mc @backlog
  Scenario: A pull request thread is still prepared when its branch cannot be set to follow the remote
    Given the remote cannot be reached when the branch is about to be set to follow it
    When the user starts a thread on pull request 42 in the local checkout
    Then the checkout is on the pull request's branch
    And the thread is prepared without an upstream

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (checkoutChangeRequest, fj)
  @mc @backlog
  Scenario Outline: A Forgejo pull request is checked out from the server's own pull request ref
    Given the Forgejo CLI is signed in and the checkout's remote is reached over <protocol>
    And <branch state>
    When the user starts a thread on Forgejo pull request 42 in the local checkout
    Then pull request 42's head is fetched from the repository's <protocol> address
    And the checkout is on <result>

    Examples:
      | protocol | branch state                      | result                                         |
      | HTTPS    | the checkout has no "pulls/42"    | a new branch "pulls/42" at the fetched head    |
      | SSH      | the checkout has no "pulls/42"    | a new branch "pulls/42" at the fetched head    |
      | HTTPS    | the checkout has a "pulls/42"     | the existing branch "pulls/42"                 |

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (checkoutChangeRequest, force: reset --keep)
  @mc @backlog
  Scenario: A forced Forgejo checkout brings the branch to the pull request's head and keeps uncommitted files
    Given the checkout has a branch "pulls/42" behind pull request 42's head and an uncommitted file
    When the user starts a thread on Forgejo pull request 42 in the local checkout forcing the update
    Then the branch is at pull request 42's head
    And the uncommitted file is still there

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (getPull: number from a reference)
  @mc @backlog
  Scenario: A Forgejo reference with no pull request number is refused
    When the user starts a thread on the Forgejo reference "acme/shop"
    Then the user is told to specify a pull request number or Forgejo pull request URL

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (listChangeRequests)
  @mc @backlog
  Scenario: Forgejo pull requests of a branch are read newest first until enough are found
    Given the branch "feature/tax" has pull requests on Forgejo among 120 others
    When the MC lists the pull requests of "feature/tax" asking for none in particular
    Then pull requests are read 50 at a time, the most recently updated first
    And only those whose head is "feature/tax" are kept, up to 20
    And reading stops when a page comes back empty

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (listChangeRequests: state merged asks closed)
  @mc @backlog
  Scenario Outline: Forgejo has no merged list so merged pull requests are picked out of the closed ones
    Given the branch "feature/tax" has one merged and one closed pull request on Forgejo
    When the MC lists the <state> pull requests of "feature/tax"
    Then only <returned> is returned

    Examples:
      | state  | returned                  |
      | merged | the merged pull request   |
      | closed | the closed pull request   |

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (createChangeRequest)
  @mc @backlog
  Scenario: A Forgejo pull request from a fork is opened against the repository it targets
    Given the branch "tax" lives in the fork "sam/shop" of "acme/shop"
    When the user opens a pull request from it on Forgejo
    Then the pull request is created in "acme/shop" with the head "sam:tax"

  @desktop @mobile @tui @backlog-mobile
  Scenario: Starting a pull request thread from a pasted link
    When the user pastes "https://github.com/acme/shop/pull/42" to start a pull request thread
    Then the user sees the pull request's title and branches before choosing local or worktree

  @backlog @desktop
  Scenario Outline: A pull request can be pasted as its host's link or checkout command
    When the user pastes "<reference>" to start a pull request thread
    Then the pull request number is read as <number>

    Examples:
      | reference                                                     | number |
      | https://gitlab.com/acme/shop/-/merge_requests/7               | 7      |
      | https://codeberg.org/acme/shop/pulls/7                        | 7      |
      | https://dev.azure.com/acme/shop/_git/web/pullrequest/7        | 7      |
      | https://acme.visualstudio.com/shop/_git/web/pullrequest/7     | 7      |
      | gh pr checkout 7                                              | 7      |
      | glab mr checkout 7                                            | 7      |
      | tea pr checkout 7                                             | 7      |
      | az repos pr checkout --id 7                                   | 7      |

  @backlog @desktop
  Scenario: A pull request reference nobody can read is refused
    When the user types "see the tax change" to start a pull request thread
    Then the user is told "Use a pull request URL, checkout command, 123, or #123."
    And neither local nor worktree can be chosen

  @backlog @desktop
  Scenario: Clearing the reference asks for one
    Given the user typed "42" to start a pull request thread
    When the user clears the reference
    Then the user is told "Paste a pull request URL, checkout command, or enter 123 / #123."

  @backlog @desktop
  Scenario: Choosing waits until the pull request is resolved
    When the user types "42" to start a pull request thread
    Then the user is told "Resolving pull request..." until its title and branches arrive
    And neither local nor worktree can be chosen until then

  @backlog @desktop
  Scenario: A pull request that cannot be resolved says why
    Given the host answers that pull request 9999 does not exist
    When the user types "9999" to start a pull request thread
    Then the user is told the host's reason in the dialog
    And neither local nor worktree can be chosen

  @backlog @desktop
  Scenario: A pull request thread is not abandoned while it is prepared
    Given the user chose to start a thread on pull request 42 in a new worktree
    When the checkout is still being prepared
    Then the dialog says "Preparing worktree..." and cannot be cancelled
    And local and worktree cannot be chosen again

  @backlog @desktop
  Scenario Outline: A pull request thread that could not be prepared stays open with the reason
    Given the MC fails to prepare pull request 42 <how>
    When the user starts a thread on pull request 42 in a new worktree
    Then the dialog stays open and says "<message>"
    And the user can choose local or worktree again

    Examples:
      | how                             | message                                  |
      | saying "Worktree already used." | Worktree already used.                   |
      | without saying why              | Failed to prepare pull request thread.   |

  @mc @desktop
  Scenario: Linking a pull request to a thread
    Given the thread "Tax work" has no linked pull request
    When the user links pull request 42 to "Tax work"
    Then "Tax work" lists pull request 42 with its current state

  @mc @desktop
  Scenario: Unlinking a pull request from a thread
    Given pull request 42 is linked to "Tax work"
    When the user unlinks pull request 42
    Then "Tax work" no longer lists pull request 42

  @mc @desktop
  Scenario: A thread links several pull requests across repositories
    When the user links "acme/shop" pull request 42 and "acme/api" pull request 7 to "Tax work"
    Then "Tax work" lists both pull requests

  @mc
  Scenario: The agent links the pull request it opened
    When the agent in "Tax work" opens pull request 43 and links it with its tool
    Then "Tax work" lists pull request 43

  @mc
  Scenario: Creating a pull request from a thread links it
    When the user creates a pull request from "Tax work"
    Then "Tax work" lists the new pull request

  @mc
  Scenario: The branch's pull request is discovered on its own
    Given "Tax work" is on the branch "feature/tax" with no linked pull request
    When someone opens a pull request for "feature/tax" on GitHub
    Then within a minute "Tax work" shows that pull request as its branch's

  @mc
  Scenario: A merged link moves to the branch's open pull request
    Given "Tax work" shows pull request 40 which has merged
    And "feature/tax" now has the open pull request 44
    When the thread's pull requests are checked again
    Then "Tax work" shows pull request 44

  @mc @desktop
  Scenario: Linked pull requests stay current
    Given pull request 42 is linked to "Tax work"
    When a review is submitted on pull request 42 on GitHub
    Then "Tax work" shows the new review state after the next sync

  @mc
  Scenario: Merged links are left alone
    Given pull request 42 is linked to "Tax work" and has merged
    When the sync sweep runs
    Then pull request 42 is not read again

  @mc
  Scenario: A pull request lists every thread linked to it, archived ones included
    Given pull request 42 is linked to "Tax work" and to the archived thread "Old tax"
    When the user asks which threads are linked to pull request 42
    Then both "Tax work" and "Old tax" are listed

  @desktop @mobile @backlog-mobile
  Scenario: Linking from a pull request link in the conversation
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    When the user links that pull request from the mention
    Then "Tax work" lists pull request 42

  @backlog @desktop
  Scenario: Hovering a pull request link shows what it points to
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    When the user rests the pointer on that link
    Then a card shows "acme/shop" #42, its state, its title, its author and when it was opened

  @backlog @desktop
  Scenario: A pull request link that cannot be read shows the address
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    And the MC cannot read pull request 42
    When the user rests the pointer on that link
    Then the card shows "https://github.com/acme/shop/pull/42"

  @backlog @desktop
  Scenario: Clicking a pull request link opens it in HAL-C2
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    When the user clicks that link
    Then pull request 42 opens in HAL-C2

  @backlog @desktop
  Scenario: Clicking a pull request link the MC cannot resolve opens it in the browser
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    And the MC cannot read pull request 42
    When the user clicks that link
    Then the browser opens "https://github.com/acme/shop/pull/42"

  # Legacy: apps/web/src/lib/openPullRequestLink.test.ts (shouldOpenPullRequestExternally)
  @backlog @desktop
  Scenario: A click with the modifier key opens a pull request link in the browser
    Given a message in "Tax work" mentions "https://github.com/acme/shop/pull/42"
    When the user clicks that link holding the modifier key
    Then the browser opens "https://github.com/acme/shop/pull/42"
    And pull request 42 does not open in HAL-C2

  # Legacy: apps/web/src/lib/openPullRequestLink.test.ts (findProjectForChangeRequest keeps two hosts apart, claims nothing for a lookalike host)
  @backlog @desktop
  Scenario Outline: A link on a host no project is checked out from goes to the browser
    Given a message in "Tax work" mentions "<link>"
    And no project is checked out from that host
    When the user clicks that link
    Then the browser opens "<link>"
    And it is not opened as a pull request of the public host

    Examples:
      | link                                           |
      | https://github.example.com/acme/shop/pull/42   |
      | https://github.com.evil.test/acme/shop/pull/42 |

  # Legacy: apps/web/src/lib/openPullRequestLink.test.ts (parseChangeRequestUrl claims nothing it cannot be sure of)
  @backlog @desktop
  Scenario Outline: A link that is not a pull request is left to the browser
    Given a message in "Tax work" mentions "<link>"
    When the user clicks that link
    Then the browser opens "<link>"

    Examples:
      | link                                            |
      | https://github.com/acme/shop/commit/0a1b2c3     |
      | https://github.com/acme/shop                    |
      | https://github.com/acme/shop/pull/abc           |
      | https://gitlab.com/acme/shop/-/snippets/12      |
      | https://blog.example.test/2026/updates/pull/3   |

  # Legacy: apps/web/src/lib/openPullRequestLink.ts (pullRequestCandidateUrlFromReferenceAutolink), apps/web/src/components/pullRequest/PullRequestLinkPreview.tsx (confirmBeforeOpen)
  @backlog @desktop
  Scenario: A written number that is a pull request opens as one
    Given a message in "Tax work" mentions "#42" of "acme/shop", which the message links to GitHub's page for issue 42
    And the host knows 42 as a pull request
    When the user clicks that link
    Then pull request 42 opens in HAL-C2

  # Legacy: apps/web/src/lib/openPullRequestLink.ts (pullRequestCandidateUrlFromReferenceAutolink), apps/web/src/components/pullRequest/PullRequestLinkPreview.tsx (onOpenFallback)
  @backlog @desktop
  Scenario: A written number that is an issue opens in the browser
    Given a message in "Tax work" mentions "#42" of "acme/shop", which the message links to GitHub's page for issue 42
    And the host knows 42 as an issue
    When the user clicks that link
    Then the browser opens "https://github.com/acme/shop/issues/42"

  @backlog @desktop
  Scenario Outline: A pull request number can be copied or opened where it lives
    When the user opens the menu of the number of a pull request of <host>
    Then the menu offers "Copy link" and "<open>"

    Examples:
      | host         | open                 |
      | GitHub       | Open on GitHub       |
      | GitLab       | Open on GitLab       |
      | Forgejo      | Open on Forgejo      |
      | Bitbucket    | Open on Bitbucket    |
      | Azure DevOps | Open on Azure DevOps |

  @backlog @desktop
  Scenario Outline: The pull request number's menu says when it could not act
    Given the clipboard cannot be written and the browser cannot be opened
    When the user chooses "<choice>" from the menu of a pull request number
    Then the user sees an "error" toast "<toast>"

    Examples:
      | choice | toast                    |
      | Copy link | Could not copy the link |
      | Open on GitHub | Could not open the link |

  # Links are decided by host, as the web's usePullRequestLinking and
  # findProjectOnChangeRequestHost do: any project on a host lends the MC its
  # credentials there, so a repository nobody has checked out still links.
  @desktop @mobile @backlog-mobile
  Scenario: A pull request from another repository on a host a project reads
    When the user links "https://github.com/other/repo/pull/1"
    Then "Tax work" lists pull request 1 of "other/repo"

  @desktop @mobile @backlog-mobile
  Scenario: A pull request on a host no project can read
    When the user links "https://gitlab.com/other/repo/-/merge_requests/1"
    Then the user is told no project in this environment can read "gitlab.com/other/repo"

  # Azure DevOps reads use the checkout's organization and project, not the
  # host's credentials, so there it takes a project of that repository.
  @desktop @mobile @backlog-mobile
  Scenario: An Azure DevOps pull request needs a project of its own repository
    Given the environment also has the Azure DevOps project "dev.azure.com/acme/shop/_git/web"
    When the user links "https://dev.azure.com/acme/shop/_git/api/pullrequest/1"
    Then the user is told no project in this environment can read "dev.azure.com/acme/shop/_git/api"
    When the user links "https://dev.azure.com/acme/shop/_git/web/pullrequest/1"
    Then "Tax work" lists pull request 1 of "acme/shop/_git/web"

  @desktop @mobile @backlog-mobile
  Scenario: A pull request the MC does not link says why
    Given the thread "Tax work" has no linked pull request
    And the MC refuses to link pull requests to "Tax work"
    When the user links pull request 42 to "Tax work"
    Then the user is told pull request 42 could not be linked
    And "Tax work" lists no pull requests

  @backlog @desktop
  Scenario: The link dialog asks for a reference before it links
    Given the user is linking a pull request to "Tax work"
    When the user types "tax" as the pull request to link
    Then the user is told "Use a pull request URL, 123, or #123."
    And the pull request cannot be linked
    When the user clears the pull request to link
    Then the user is told "Paste a pull request URL or enter 123 / #123."

  @backlog @desktop
  Scenario: A bare number needs the thread's own project to be understood
    Given "Tax work" is not in a project
    When the user links "42" to "Tax work"
    Then the user is told "Paste a full URL to link a pull request from another repository."
    And the pull request cannot be linked

  @backlog @desktop
  Scenario: A bare number on a host with no pull request address
    Given the project of "Tax work" is on a host whose pull request addresses are not known
    When the user links "42" to "Tax work"
    Then the user is told "Paste a full URL; this project's host has no known pull request URL."
    And the pull request cannot be linked

  @backlog @desktop
  Scenario: Linking shows it is working and says why it failed
    Given the MC takes a while to link pull requests to "Tax work"
    When the user links pull request 42 to "Tax work"
    Then the link dialog shows "Linking..." and cannot be submitted again
    Given the MC refuses to link pull requests to "Tax work"
    When the user links pull request 42 to "Tax work" again
    Then the link dialog says the pull request could not be linked and stays open

  @backlog @desktop
  Scenario Outline: A linked pull request says how it came to be linked
    Given pull request 42 was <how> to "Tax work"
    When the user opens the pull requests of "Tax work"
    Then pull request 42 says "<label>"

    Examples:
      | how                                  | label                     |
      | linked by the user                   | Linked by you             |
      | created from the thread              | Created from this thread  |
      | linked by the agent                  | Linked by the agent       |
      | found in the stack of another layer  | Found in the stack        |
      | dismissed from the stack             | Dismissed                 |

  @backlog @desktop
  Scenario: A stack layer is dismissed from the thread rather than unlinked
    Given pull request 43 is a layer found in the stack of "Tax work"
    When the user opens the actions of pull request 43 in "Tax work"
    Then the action is "Dismiss from thread"
    And a pull request the user linked is offered "Unlink from thread" instead

  @backlog @desktop
  Scenario: A stack the thread's pull request belongs to says what merging does
    Given pull request 42 is a layer of a GitHub stack of 3
    When the user opens the pull requests of "Tax work"
    Then the user is told "GitHub stack of 3: merging a layer lands the ones below it."

  @backlog @desktop
  Scenario: Pull requests chained only by their base branches say so
    Given pull requests 42, 43 and 44 are chained by their base branches on a host with no stacks of its own
    When the user opens the pull requests of "Tax work"
    Then the user is told "3 pull requests chained by base branch."

  @backlog @desktop
  Scenario: A link the host has not been asked about yet shows what is known
    Given pull request 42 was just linked to "Tax work" and the host has not answered
    When the user opens the pull requests of "Tax work"
    Then pull request 42 is listed with its repository and "Waiting for host state"

  @backlog @desktop
  Scenario: A linked pull request says how and when it was linked
    Given pull request 42 was linked to "Tax work" by the user an hour ago
    When the user rests the pointer on the number of pull request 42
    Then the user is told "Linked by you" and how long ago

  @backlog @desktop
  Scenario: A linked pull request's link can be copied or opened from its row
    Given pull request 42 is linked to "Tax work"
    When the user opens the actions of pull request 42 in "Tax work"
    Then the user can copy its link
    And the user can open it

  @backlog @desktop
  Scenario: An environment without several links per thread says so
    Given the environment does not support several linked pull requests per thread
    When the user opens the pull requests of "Tax work"
    Then the user is told "Linked pull requests unavailable"
    And the user is told "This environment does not support multiple linked pull requests."

  @backlog @desktop
  Scenario: A thread without pull requests says so
    Given "Tax work" has no linked pull request
    When the user opens the pull requests of "Tax work"
    Then the user is told "No linked pull requests"
    And the user can link one

  @backlog @desktop
  Scenario: A pull request says how many threads work on it
    Given pull request 42 is linked to "Tax work" and to "Tax review"
    When the user reads pull request 42
    Then it says "Linked from 2 threads"
    And choosing it searches the threads for pull request 42

  @backlog @desktop
  Scenario: Linking a pull request to a thread chosen from a list
    Given pull request 42 is linked to no thread
    When the user chooses to link pull request 42 to a thread
    Then the user sees the active threads, newest first, with a way to search threads and projects
    And archived threads are not offered
    When the user chooses "Tax work"
    Then "Tax work" lists pull request 42

  @backlog @desktop
  Scenario: A thread that already has the pull request cannot be chosen again
    Given pull request 42 is linked to "Tax work"
    When the user chooses to link pull request 42 to a thread
    Then "Tax work" is shown as "Linked" and cannot be chosen
    And the menu offers to unlink pull request 42 from this thread

  @backlog @desktop
  Scenario Outline: A link that could not be changed is reported
    Given the MC refuses to <change> pull request 42 <direction> "Tax work"
    When the user tries to <change> pull request 42 <direction> "Tax work"
    Then the user sees an "error" toast "Could not <change> the pull request"

    Examples:
      | change | direction |
      | link   | to        |
      | unlink | from      |

  @desktop @mobile @backlog-mobile
  Scenario: Opening a linked pull request in the browser
    Given pull request 42 is linked to "Tax work"
    When the user opens pull request 42 from "Tax work"
    Then the browser opens "https://github.com/acme/shop/pull/42"

  @desktop @mobile @backlog-mobile
  Scenario: Refreshing the linked pull requests reads them from the host again
    Given pull request 42 is linked to "Tax work"
    And a review is submitted on pull request 42 on GitHub
    When the user refreshes the pull requests of "Tax work"
    Then pull request 42 is read from GitHub again
    And "Tax work" shows the new review state

  @desktop @mobile @backlog-mobile
  Scenario: Linked pull requests of an unreachable environment stay as last synced
    Given pull request 42 is linked to "Tax work"
    When the environment of "Tax work" becomes unreachable
    Then "Tax work" still lists pull request 42
    And the user cannot link, unlink or refresh pull requests
    When the environment of "Tax work" is reachable again
    Then the user can link, unlink and refresh pull requests

  @desktop
  Scenario: Opening the thread's pull request from the composer
    Given pull request 42 is the branch's pull request of "Tax work"
    When the user opens the pull request from the thread
    Then pull request 42 opens

  @backlog @mobile
  Scenario: The phone's git overview lists linked reviews and stacks
    Given pull request 42 is linked to "Tax work"
    When the user opens the git overview of "Tax work" on the phone
    Then pull request 42 is listed with its stack

  @backlog @mc
  Scenario: A link preview asks the host for no more than its card needs
    When a client asks for the preview of pull request 42
    Then the answer carries the repository, number, title, link, author, state, draft flag and creation time
    And it carries none of the conversation, checks or files

  @backlog @mc
  Scenario: A preview is not read again within a short while
    Given the preview of pull request 42 was read a few seconds ago
    When a client asks for it again
    Then the answer comes without asking the host
    But a change made to pull request 42 from HAL-C2 or a refresh makes the next preview ask the host

  @backlog @mc
  Scenario: A preview never waits for a full read of the same pull request
    Given the details of pull request 42 are still being read
    When a client asks for its preview
    Then the preview is answered without waiting for the details

  @backlog @mc
  Scenario: A preview is made from details held a moment ago but never from stale ones
    Given the details of pull request 42 were read 10 seconds ago
    When a client asks for its preview
    Then it is answered from those details without asking the host
    When the details were read 20 seconds ago instead
    Then the host is asked for the preview

  @backlog @mc
  Scenario: Previews already held are still shown while a rate limit pauses new ones
    Given the host is rate limited
    And the preview of pull request 1 is held
    When a client asks for the previews of pull requests 1 and 2
    Then the preview of pull request 1 is returned
    And pull request 2 is refused as paused until the limit resets

  @backlog @mc
  Scenario: A host without a narrow preview answers from the full pull request
    Given the host has no narrow read for a pull request
    When a client asks for the preview of pull request 42
    Then the preview is made from the host's full answer

  @backlog @mc
  Scenario: Another project finishing a turn does not discard previews
    Given the previews of "acme/web" and "acme/docs" are held
    When a turn finishes in "acme/docs"
    Then the preview of "acme/web" is still answered without asking the host
