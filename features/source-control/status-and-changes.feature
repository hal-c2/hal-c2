# Sources:
#   https://github.com/pingdotgg/t3code/pull/27103
#   https://github.com/pingdotgg/t3code/pull/29817
#   https://github.com/pingdotgg/t3code/pull/31928
#   https://github.com/pingdotgg/t3code/pull/29586
#   https://github.com/pingdotgg/t3code/pull/32162
#   https://github.com/pingdotgg/t3code/pull/25207
#   https://github.com/pingdotgg/t3code/pull/24258
#   https://github.com/pingdotgg/t3code/pull/21046
#   https://github.com/pingdotgg/t3code/pull/14942
#   https://github.com/pingdotgg/t3code/pull/20175
#   https://github.com/pingdotgg/t3code/pull/16453
#   https://github.com/pingdotgg/t3code/pull/20412
#   https://github.com/pingdotgg/t3code/pull/19371
#   https://github.com/pingdotgg/t3code/pull/20440
#   https://github.com/pingdotgg/t3code/pull/12465
#   https://github.com/pingdotgg/t3code/pull/16771
#   https://github.com/pingdotgg/t3code/pull/13894
#   https://github.com/pingdotgg/t3code/pull/14718
#   docs/user/source-control.md
#   packages/contracts/src/vcs.ts (VcsStatusLocalResult, VcsStatusRemoteResult, VcsStatusStreamEvent, VcsDriverKind)
#   packages/contracts/src/rpc.ts (vcs.refreshStatus, subscribeVcsStatus, vcs.init)
#   apps/server-ex/lib/hal_c2/vcs.ex (status, init)
#   apps/server-ex/lib/hal_c2/vcs/watch.ex
#   apps/server-ex/lib/hal_c2/pull_requests/branches.ex (one answer per branch's pull request)
#   apps/server/src/git/GitManager.ts, apps/server/src/vcs/VcsStatusBroadcaster.ts (pull request lookup cadence, shared polling, automatic pull)
#   apps/server/src/vcs/VcsProjectConfig.ts, VcsDriverRegistry.ts, VcsProcess.ts (project vcs.json, detection, concurrency)
#   apps/server/src/vcs/GitVcsDriverCore.ts (index lock, unborn HEAD, upstream refresh back-off)
#   apps/server/src/orchestration-v2/RunFinalizationService.ts (which turn ends check the pull request)
#   apps/server-ex/lib/hal_c2/source_control/change_requests.ex (GitLab, Forgejo, Azure DevOps, Bitbucket)
#   apps/server-ex/lib/hal_c2/background_policy.ex (automaticGitFetchInterval)
#   apps/server-ex/config/runtime.exs (HAL_C2_MC_NO_AUTO_ACTIONS)
#   apps/web/src/components/GitActionsControl.tsx (Initialize Git)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (Initialize Git, git pill)
#   apps/tui/src/gitActions.logic.ts (mergeVcsStatus, resolveGitQuickAction)
#   apps/tui/src/connection.ts (subscribeVcsStatus)
#   https://github.com/pingdotgg/t3code/pull/28600
#   https://github.com/pingdotgg/t3code/pull/28439
#   https://github.com/pingdotgg/t3code/pull/22119
#   https://github.com/pingdotgg/t3code/pull/31342
#   https://github.com/pingdotgg/t3code/pull/26125
#   https://github.com/pingdotgg/t3code/pull/29180
#   https://github.com/pingdotgg/t3code/pull/29670
#   https://github.com/pingdotgg/t3code/pull/30085

Feature: Repository status and working tree changes
  The checkout behind a thread reports its branch, its uncommitted changes and how it stands
  against its upstream, and keeps that picture current while someone is looking at it.

  Background:
    Given a connected environment with the project "shop" in a git repository

  @mc
  Scenario: Status reports the branch and the uncommitted files
    Given the user has changed "src/cart.ts" and added "src/tax.ts" on the branch "feature/tax"
    When status is read for "shop"
    Then the status names the branch "feature/tax"
    And it lists both files with their inserted and deleted line counts
    And it says the working tree has changes

  @mc
  Scenario: A file whose name starts or ends with a space keeps its exact path
    Given the user has added " leading.txt" to "shop"
    When status is read for "shop"
    Then it lists " leading.txt" with its leading space
    And a git action given " leading.txt" acts on that file, not on "leading.txt"

  # Upstream #20175: status parsed git's display output, which quotes and escapes some paths.
  # Upstream #19371: a quoted file name lost a leading U+FEFF, the invisible byte-order mark (the last row).
  @mc @priority-high
  Scenario Outline: Status lists changed files by their real paths
    Given the user has <change> in "shop"
    When status is read for "shop"
    Then it lists <listed>
    And a git action given that path acts on that file

    Examples:
      | change                                   | listed                                        |
      | added "docs/résumé.md"                   | "docs/résumé.md"                              |
      | added 'notes/a "quoted" name.txt'        | 'notes/a "quoted" name.txt'                   |
      | renamed "src/cart.ts" to "src/basket.ts" | "src/basket.ts" as renamed from "src/cart.ts" |
      | renamed "old.txt" to a name of U+FEFF followed by "note.txt" | that name, U+FEFF included, as renamed from "old.txt" |

  # Upstream #16771: counting the lines of thousands of untracked files pegged the CPU.
  @backlog @mc @priority-low
  Scenario: Status over 5,000 untracked files says its totals are incomplete
    Given "shop" has 6,000 untracked files and a change to "src/cart.ts"
    When status is read for "shop"
    Then it says the line totals are incomplete instead of counting every untracked file
    And the thread's changes show no totals
    And the diff shows the change to "src/cart.ts", marked as cut short

  @mc
  Scenario: Status reports how the branch stands against its upstream
    Given "feature/tax" tracks "origin/feature/tax" and is 2 commits ahead and 1 behind
    When status is read for "shop"
    Then the status says the branch has an upstream
    And it reports 2 commits ahead and 1 behind

  # Upstream #29180: a local branch literally named "origin/feature/tax" made the upstream's
  # remote read as "remotes", so background fetches failed and a push saved a base that does
  # not exist.
  @mc
  Scenario: A local branch named like the upstream does not hide the upstream's remote
    Given "feature/tax" tracks "origin/feature/tax" and is 1 commit ahead
    And the repository also has a local branch named "origin/feature/tax"
    When status is read for "shop"
    Then the upstream is "origin/feature/tax" on the remote "origin"
    And it reports 1 commit ahead
    And pushing "feature/tax" keeps "origin/feature/tax" as its base

  # Upstream #29670: a branch tracking the local "feature/part-1" read "feature" as its remote,
  # so every status refresh fetched a remote that does not exist and logged a failure.
  @mc @priority-low
  Scenario: A branch that tracks a local branch fetches nothing
    Given "part-2" tracks the local branch "feature/part-1" and is 1 commit ahead of it
    When status is read for "shop"
    Then nothing is fetched for "part-2"
    And it reports 1 commit ahead

  # Upstream #16453: a branch without an upstream that is configured to merge into "upstream/main"
  # was still compared with the fork's "origin/main".
  @mc
  Scenario: A branch's changes are compared with the base it is configured to merge into
    Given the branch "fix-tax" has no upstream and is set to merge into "upstream/main"
    And the fork's "origin/main" is behind "upstream/main"
    When status is read for "shop" on "fix-tax"
    Then its changes and the commits it is ahead are counted against "upstream/main"
    And commits only "upstream/main" has are not shown as the branch's changes

  # Delivered natively (WorkspaceController follows the checkout's vcs status); no desktop test yet.
  @mc @desktop @tui
  Scenario: Status follows the checkout while the thread is open
    Given the user is looking at a thread in "shop"
    When the agent's turn ends after editing a file
    Then the thread's status shows the new change without the user asking for a refresh

  @mc
  Scenario: Status refreshes after a git action finishes
    Given the user is looking at a thread in "shop" with uncommitted changes
    When the user commits the changes
    Then the thread's status reports a clean working tree

  @mc
  Scenario: The remote side is fetched on the automatic fetch interval
    Given the automatic Git fetch interval is 30 seconds
    And a client in front is showing a thread in "shop"
    When 30 seconds pass
    Then the MC fetches from the remote and the ahead and behind counts are updated

  # Upstream #31342: after a turn merged a branch, the counts stayed stale while the background
  # activity profile held periodic work back.
  @backlog @mc
  Scenario: A finished turn updates the ahead and behind counts without fetching
    Given "feature/tax" is 3 commits ahead and 5 behind its upstream
    And the background activity profile holds periodic Git work back
    When a turn merges the upstream into "feature/tax" and finishes
    Then the thread shows 7 commits ahead and 0 behind
    And nothing is fetched from the remote

  # Upstream #28439: an empty branch total of +0 -0 hid the working tree's edits, so Changes read
  # +0 -0 while the diff showed real changes.
  @backlog @desktop @mobile
  Scenario Outline: The Changes totals show the edits the diff shows
    Given the thread's branch in "shop" has <branch> and its working tree has 12 inserted and 3 deleted lines
    When the user looks at the thread's Changes totals
    Then they read <totals>

    Examples:
      | branch                                    | totals   |
      | no changes of its own                     | +12 -3   |
      | 40 inserted and 5 deleted lines committed | +40 -5   |

  # Upstream #30085: with origin/HEAD missing the totals were silently counted against origin/master,
  # and nothing said which base they came from.
  @backlog @desktop @mobile
  Scenario: The Changes totals name the base they are counted against
    Given the thread's worktree in "shop" is compared against "origin/master"
    When the user looks at the thread's Changes totals
    Then they read "vs origin/master" beside the totals
    And the full name of the base can be seen on hover

  # Upstream #22119: only a remote named "origin" counted, so a repository cloned with another
  # remote name had no Push or Create PR and was offered "Publish repository".
  @mc
  Scenario Outline: A repository's only remote is its primary remote whatever its name
    Given "shop" has <remotes>
    When the MC reads the git status of "shop"
    Then "shop" <has> a primary remote

    Examples:
      | remotes                         | has         |
      | only the remote "github"        | has         |
      | the remotes "origin" and "fork" | has         |
      | no remote                       | does not have |

  # Upstream #28600: the lines-changed totals stayed counted against the old base when only the
  # base moved and the ahead and behind counts did not.
  @backlog @mc
  Scenario Outline: The Changes totals follow a base that moved
    Given the thread's worktree in "shop" shows its Changes totals
    When <what>
    Then the Changes totals are counted against the new base

    Examples:
      | what                                                                  |
      | an automatic fetch finds the base branch moved, with the same ahead and behind counts |
      | the user refreshes and the merge base has changed                     |
      | another client read the totals while the fetch was running            |

  # Upstream #26125: a status read that straddled the automatic rename after a thread's first
  # message guessed the remote's default branch as the base, and showed hundreds of thousands
  # of changed lines.
  @backlog @mc
  Scenario: Changes totals read during the branch's automatic rename are not counted against a guess
    Given a new thread's worktree in "shop" has three changed lines
    When its temporary branch is renamed while its status is being read
    Then the Changes totals show the three working tree lines
    And they are never counted against the remote's default branch

  @mc
  Scenario: A fetch interval of zero never fetches on its own
    Given the automatic Git fetch interval is 0 seconds
    When a client shows a thread in "shop" for several minutes
    Then the MC never fetches from the remote without being asked

  @mc
  Scenario: Nobody watching means no background fetches
    Given no client is showing a thread in "shop"
    When the fetch interval elapses
    Then the MC does not fetch "shop" from the remote

  # A scratch MC on a copy of real data, as `mise run desktop:cua` starts one, names real checkouts.
  @mc
  Scenario: An MC without automatic actions does not fetch on its own
    Given the MC runs without automatic actions
    And the automatic Git fetch interval is 30 seconds
    And a client in front is showing a thread in "shop"
    When the fetch interval elapses
    Then the MC does not fetch "shop" from the remote

  @mc
  Scenario: Status names the open pull request for a GitHub branch
    Given "feature/tax" has an open draft pull request on GitHub
    When status is read for "shop"
    Then the status carries that pull request with its state open and marked as a draft

  @mc
  Scenario: On the default branch only an open pull request counts
    Given "main" once had a merged pull request from the same branch name
    When status is read on "main"
    Then the status carries no pull request

  @mc
  Scenario Outline: Status names the open change request on other hosts
    Given "shop" has its primary remote on <host>
    And the current branch has an open change request there
    When status is read for "shop"
    Then the status carries that change request

    Examples:
      | host         |
      | GitLab       |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @mc
  Scenario: A folder that is not a repository says so
    Given the project "notes" is not in a git repository
    When status is read for "notes"
    Then the status says it is not a repository

  # Upstream #20440: every git process runs with safe.bareRepository=explicit, so a bare
  # repository hidden in a project's files cannot bring its config or hooks into HAL-C2's git calls.
  # A project whose own folder is a bare repository is still opened, by naming it explicitly
  # (mc/orchestration/projects.feature, "A project in a bare repository carries its repository").
  @mc @priority-high
  Scenario: A bare repository among a project's files is not opened as a repository
    Given the folder "fixtures/evil" in "shop" is shaped like a bare repository with a hook
    When HAL-C2 runs git inside "fixtures/evil"
    Then "fixtures/evil" is not opened as a repository
    And the hook does not run

  # Legacy: apps/server/src/git/GitManager.test.ts (status returns an explicit non-repo result for deleted directories)
  @mc
  Scenario: A folder that has been deleted says it is not a repository
    Given the project "notes" is not in a git repository
    And the folder of "notes" was deleted
    When status is read for "notes"
    Then the status says it is not a repository
    And no failure is reported

  # Upstream #14942: without git installed, a folder read as a failure to start git.
  @mc
  Scenario: A folder on a machine without git says it is not a repository
    Given the project "notes" is not in a git repository
    And git is not installed on the MC's machine
    When status is read for "notes"
    Then the status says it is not a repository
    And no failure is reported

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (statusDetails: unborn HEAD)
  @mc @priority-high
  Scenario: A repository with no commits yet still reports its branch and changes
    Given the project "notes" is a git repository with no commits
    And "notes" holds a staged "a.txt" and an untracked "b.txt"
    When status is read for "notes"
    Then the status names the branch the first commit will go on
    And "a.txt" and "b.txt" are listed with their changed line counts

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (readStatusDetailsLocal: index lock)
  @mc @priority-high
  Scenario: A checkout whose git index is locked reports that instead of a status
    Given another git process is holding the index lock of "shop"
    When status is read for "shop"
    Then the status read fails with "Git index is locked. Status will resume when the index lock is removed."
    And the next status read after the lock is gone reports the checkout normally

  # Delivered natively (GitController, vcs.init); source-control/git-actions.feature runs it in its own words, not these steps.
  @mc @desktop
  Scenario: Initializing a repository in a plain folder
    Given the project "notes" is not in a git repository
    When the user initializes Git for "notes"
    Then "notes" becomes a git repository
    And the git actions for "notes" become available

  @tui
  Scenario: Initializing a repository from the terminal client
    Given the project "notes" is not in a git repository
    When the user initializes Git for "notes" from the terminal client
    Then "notes" becomes a git repository

  # Legacy: apps/server/src/git/GitManager.ts (lookupStatusPr, resolveLastKnownPr)
  @mc @backlog
  Scenario: A pull request already shown stays when the host cannot be reached
    Given status showed an open pull request for "feature/tax"
    And the host now refuses or cannot be reached
    When status is read for "shop" again
    Then the status still carries that pull request

  # Legacy: apps/server/src/git/GitManager.ts (resolveLastKnownPr: remote identity)
  @mc @backlog
  Scenario: A branch moved to another remote does not keep the old pull request
    Given status showed an open pull request for "feature/tax" on the remote "origin"
    And the host now cannot be reached
    When the branch's remote is changed to a different repository and status is read again
    Then the status carries no pull request
  # Upstream #21046: the local scan is published before a slow pull request lookup finishes.
  @mc
  Scenario: Local status is not held back by a slow pull request lookup
    Given the host is slow to answer the pull request lookup for "feature/tax"
    When the user changes "src/cart.ts" while the lookup is still waiting
    Then the status shows the change to "src/cart.ts" before the lookup answers

  # Upstream #32162: after a restart the background pull request lookups took every git slot, so
  # status waited one to two minutes behind them.
  @backlog @mc @priority-low
  Scenario: Pull request lookups in the background after a restart do not hold up status
    Given the MC has just restarted and is looking up the pull requests of many threads' branches
    When status is read for "shop"
    Then the status is read without waiting for those lookups
    And the background lookups run no more than two git processes at a time

  # Upstream #21046: a lookup started on one branch never fills in the pull request of the branch checked out next.
  @mc @priority-high
  Scenario: A late pull request answer for the previous branch is not shown on the new one
    Given a pull request lookup for "feature/tax" is still waiting
    When the user checks out "feature/cart" and the lookup for "feature/tax" then answers
    Then the status for "feature/cart" does not carry the pull request of "feature/tax"
    And a later lookup still finds the pull request of "feature/cart"

  # Upstream #24258: a branch with the same name as a tag read as "heads/<name>" in remote status and review.
  @mc
  Scenario: A branch named like a tag is still reported by its name
    Given the checked out branch "release" has a tag also named "release"
    When status is read for "shop"
    Then the status names the branch "release", not "heads/release"
    And the review compares "release" with the default branch
    And the pull request of "release" is still found

  # Upstream #25207: status of a repository with thousands of long changed paths failed on an output cap.
  @mc
  Scenario: Status of a repository with thousands of changed files is complete
    Given the user has changed 6000 files with long paths in "shop"
    When status is read for "shop"
    Then the status lists all 6000 files with their line counts
    And a commit can be prepared from them


  # Legacy: apps/server/src/git/GitManager.ts (prLookupFailureTtl)
  @mc
  Scenario: A host that keeps refusing the pull request lookup is asked less and less often
    Given the host refuses the pull request lookup for "feature/tax" every time
    And a client in front is showing a thread in "shop" on "feature/tax"
    When the status's automatic fetch runs again and again
    Then the lookup is retried after 20 seconds, then 40 seconds, doubling up to 15 minutes
    And the first answer that succeeds brings back the normal rhythm

  # Legacy: apps/server/src/git/GitManager.ts (PR_LOOKUP_CACHE_TTL, PR_LOOKUP_NO_OPEN_PR_CACHE_TTL)
  @mc
  Scenario Outline: How soon status asks the host about a branch's pull request again depends on what it found
    Given the host's last answer for "feature/tax" was <answer>
    And a client in front is showing a thread in "shop" on "feature/tax"
    When the status's automatic fetch runs over the next minutes
    Then the host is asked again after about <wait>

    Examples:
      | answer                   | wait       |
      | an open pull request     | 1 minute   |
      | a merged pull request    | 5 minutes  |
      | no pull request at all   | 5 minutes  |

  # One answer per branch: the thread's pull request discovery and the checkout's status
  # share it (`HalC2.PullRequests.Branches`), so GitHub is asked once for both.
  @mc
  Scenario: A checkout's branch status shows the pull request the MC already found, without asking GitHub again
    Given "feature/tax" has an open draft pull request on GitHub
    And the MC has found the pull request of the thread "work" on "feature/tax"
    When a client in front is showing a thread in "shop"
    Then the status carries that pull request with its state open and marked as a draft
    And the status did not ask the host about "feature/tax"

  @mc
  Scenario: Refreshing the status asks the host about the pull request again
    Given "feature/tax" has an open draft pull request on GitHub
    And the MC has found the pull request of the thread "work" on "feature/tax"
    When status is read for "shop"
    Then the status carries that pull request with its state open and marked as a draft
    And the status asked the host about "feature/tax" again

  @mc
  Scenario: A pull request change made through HAL-C2 has the status ask the host again
    Given "feature/tax" has an open draft pull request on GitHub
    And the automatic Git fetch interval is 30 seconds
    And a client in front is showing a thread in "shop"
    When the user refreshes the pull requests
    And the status's automatic fetch runs
    Then the status asked the host about "feature/tax" again

  # Legacy: apps/server/src/git/GitManager.ts (isUnpublishedBranch)
  @mc @backlog
  Scenario: A branch that was never pushed makes no call to the host
    Given "feature/new" exists only on this machine and has no upstream
    When status is read for "shop" on "feature/new"
    Then the status carries no pull request
    And the host is not asked about the branch

  # Legacy: apps/server/src/git/GitManager.ts (resolveLookupHeadContext)
  @mc @backlog
  Scenario: A branch cut from the default branch is not given the default branch's pull requests
    Given "feature/tax" was cut from "origin/main" and still tracks it
    And an old pull request once merged "main" into another branch
    When status is read for "shop" on "feature/tax"
    Then the status carries no pull request
    And the thread is not settled because of that old pull request

  # Legacy: apps/server/src/git/GitManager.ts (resolveLookupHeadContext, findRemoteTrackingRemote)
  @mc @backlog
  Scenario Outline: A branch cut from the default branch and pushed under its own name is looked up by that name
    Given "feature/tax" was cut from "origin/main" and still tracks it
    And the remotes <remotes> hold a branch "feature/tax"
    And a pull request is open on the host for "feature/tax"
    When status is read for "shop" on "feature/tax"
    Then the status carries that pull request, found through "<remote>"

    Examples:
      | remotes              | remote |
      | "origin"             | origin |
      | "origin" and "fork"  | origin |
      | "fork"               | fork   |

  # Legacy: apps/server/src/git/GitManager.ts (matchesBranchHeadContext, GITHUB_HEAD_BRANCH_PROBE_LIMIT)
  @mc @backlog
  Scenario: Another fork's branch of the same name is not taken as the branch's pull request
    Given "patch-1" is pushed to "origin" in the user's repository
    And an open pull request on the host comes from a "patch-1" branch of someone else's fork
    When status is read for "shop" on "patch-1"
    Then the status carries no pull request

  @mc @backlog
  Scenario: A branch pushed to the user's fork without an upstream finds its pull request
    Given "fix/loader" was pushed to the remote "fork" without setting an upstream
    And an open pull request on "origin" comes from "fix/loader" on that fork
    When status is read for "shop" on "fix/loader"
    Then the status carries that pull request
    And the pull request is not linked to the thread until the user links it

  # Upstream #20412: with no "origin", the branch's remote was taken for a fork, so its pull
  # request was not found and "Commit, push & PR" tried to open a second one.
  @backlog @mc
  Scenario: A branch on a repository's only remote finds its pull request without an origin
    Given the only remote of "shop" is named "github"
    And an open pull request on "github" comes from "fix-tax"
    When status is read for "shop" on "fix-tax"
    Then the status carries that pull request
    And committing, pushing and opening a pull request from "fix-tax" uses it instead of opening another

  # Upstream #29817: on Azure DevOps a fork's newer pull request from a same-named branch took
  # the only result asked for, so the branch showed no pull request and offered to open one.
  @backlog @mc
  Scenario: On Azure DevOps a fork's same-named branch does not hide the branch's own pull request
    Given "shop" has its primary remote on Azure DevOps
    And "feature" has an open pull request in "shop"
    And a fork has a newer open pull request from its own "feature" branch
    When status is read for "shop" on "feature"
    Then the status carries the pull request from "shop"
    And creating a pull request for "feature" is not offered

  # Upstream #31928: the Azure CLI sent the branch unescaped, so a "#" cut the query off and an
  # existing pull request read as none; a changed file's path holding "#" or "&" was cut the same way.
  @backlog @mc
  Scenario: On Azure DevOps a branch whose name holds "#" finds its pull request
    Given "shop" has its primary remote on Azure DevOps
    And "user/feat/12-(#34)-slug" has an open pull request
    When status is read for "shop" on "user/feat/12-(#34)-slug"
    Then the status carries that pull request
    And reviewing it shows the whole of a changed file named "notes #1 & 2.md"

  # Upstream #29586: Azure DevOps's default-branch lookup never named the repository, so it always
  # failed and the default branch was guessed instead.
  @backlog @mc @priority-low
  Scenario Outline: On Azure DevOps the default branch is read from the repository the remote names
    Given the primary remote of "shop" is <remote>
    And the repository's default branch on Azure DevOps is "trunk"
    When status is read for "shop"
    Then the default branch is "trunk"

    Examples:
      | remote                                                   |
      | "https://dev.azure.com/acme/web/_git/shop"                |
      | "https://acme.visualstudio.com/web/_git/shop"             |
      | "git@ssh.dev.azure.com:v3/acme/web/shop"                  |

  # Upstream #29586: a name starting with "@" would make the Azure CLI read a local file instead.
  @backlog @mc @priority-low
  Scenario: On Azure DevOps a repository named with a leading "@" falls back to guessing the default branch
    Given the primary remote of "shop" is "https://dev.azure.com/acme/web/_git/@shop"
    When status is read for "shop"
    Then the Azure CLI is not asked for the default branch
    And the default branch is found the way it is for a remote without a host

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (refreshPullRequestStatus), GitManager.ts (refreshMissingPullRequest)
  @mc @priority-high
  Scenario: A pull request opened outside HAL-C2 shows up when the next turn ends
    Given a client in front is showing a thread in "shop"
    And the status has no pull request for "feature/tax"
    And someone opened a pull request for it on the host
    When the thread's turn ends
    Then the status carries that pull request without waiting for the slower recheck

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (refreshPullRequestStatus: background policy)
  @mc
  Scenario: The turn-end pull request check respects the background settings
    Given background work is paused for "shop" by the user's background activity settings
    When a thread's turn ends in "shop"
    Then the host is not asked about the pull request

  # Legacy: apps/server/src/orchestration-v2/RunFinalizationService.ts (observerLive refresh)
  @mc @backlog
  Scenario Outline: The turn-end pull request check runs only for the thread's own branch
    Given a thread in "shop" works on "feature/tax"
    And <situation>
    When the thread's turn ends
    Then the working tree changes are refreshed
    But the host is not asked about the pull request

    Examples:
      | situation                                                 |
      | the checkout is on the default branch                     |
      | the checkout is on a branch other than the thread's       |
      | the checkout has no branch checked out                    |
      | a newer turn of the thread is already running             |

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (refreshPullRequestStatus: resolves the checked-out branch again)
  @mc @priority-high
  Scenario: A pull request found for one branch is not shown after the agent checks out another
    Given the status of "shop" carries the pull request of "feature/tax"
    And the agent checks out "feature/other", which has no pull request, during its turn
    When the thread's turn ends
    Then the status carries no pull request

  # Legacy: apps/server/src/git/GitManager.ts (invalidateStatus bumps the lookup epoch)
  @mc
  Scenario Outline: What the user does asks the host again at once
    Given status showed no pull request for "feature/tax" a moment ago
    When <action>
    Then the next status asks the host about the branch again

    Examples:
      | action                                |
      | the user refreshes the status         |
      | the user pushes the branch            |
      | the user creates the pull request     |

  # Legacy: apps/server/src/git/GitManager.ts (STATUS_RESULT_CACHE_TTL)
  @mc @backlog @priority-low
  Scenario: Many clients asking for status in the same second cause one read
    Given five clients ask for the status of "shop" within one second
    Then git is asked once for the checkout's status
    And all five get the same answer

  # Upstream #27103: every refresh a subscriber asked for ran the checkout's git commands again.
  @mc @backlog @priority-low
  Scenario: A burst of refreshes reads the checkout at most twice
    Given clients ask to refresh the status of "shop" five times while one read is running
    Then the checkout's status is read at most twice
    And every client gets a status read after its own request

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (fingerprints)
  @mc @priority-low
  Scenario: A refresh that finds nothing new sends nothing to watchers
    Given a client is watching the status of "shop"
    When the status is refreshed and nothing about the checkout changed
    Then the client receives no update

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (poller per cwd)
  @mc @priority-low
  Scenario: Clients watching one checkout share a single background fetch
    Given two clients are watching the status of "shop"
    When the fetch interval elapses
    Then the MC fetches "shop" once
    And both clients receive the result

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (remoteRefreshFailureDelay)
  @mc @backlog @priority-low
  Scenario: A remote that fails to fetch is retried less and less often
    Given the automatic Git fetch interval is 30 seconds
    And the remote of "shop" cannot be reached
    When a client in front keeps showing a thread in "shop"
    Then the fetch is retried after 30 seconds, then 60 seconds, doubling up to 15 minutes
    And a longer configured interval is never shortened
    And the first fetch that succeeds returns to the configured interval

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (remoteWriteLocks)
  @mc @backlog
  Scenario: A slow background check cannot hide a pull request created while it ran
    Given a background status check for "shop" started before the pull request was created
    When the pull request is created and the slow check then finishes
    Then the status still carries the new pull request

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (maybeAutoPull)
  @mc @backlog
  Scenario Outline: A watched checkout that falls behind is pulled when it is safe to
    Given "shop" has automatic pull on
    And "shop" <state>
    When the fetch finds the upstream has new commits
    Then "shop" <result>

    Examples:
      | state                                           | result                       |
      | is a clean checkout of its default branch       | is fast-forwarded            |
      | is a clean checkout of its default branch with commits the upstream lacks | is not pulled |
      | has uncommitted changes                         | is not pulled                |
      | is on a branch other than its default           | is not pulled                |

  # Legacy: apps/server/src/vcs/VcsProjectConfig.ts
  @mc @backlog @priority-low
  Scenario Outline: A project can say which version control system it uses
    Given the project folder or a folder above it holds "<file>" naming the system "jj"
    When status is read for "shop"
    Then the status is read with the Jujutsu driver

    Examples:
      | file                |
      | .hal-c2/vcs.json    |
      | .t3/vcs.json        |

  # Legacy: apps/server/src/vcs/VcsProjectConfig.ts (a bad file falls back to automatic detection)
  @mc @backlog @priority-low
  Scenario: A version control file that cannot be read is ignored
    Given the project holds ".hal-c2/vcs.json" that is not valid JSON
    When status is read for "shop"
    Then the system is detected automatically and the status is read

  # Legacy: apps/server/src/vcs/VcsProjectConfig.ts (findConfigPath, configuredKind)
  @mc @backlog @priority-low
  Scenario Outline: Which version control file the project's choice comes from
    Given <files>
    When status is read for "shop"
    Then the status is read with the <driver> driver

    Examples:
      | files                                                                                    | driver   |
      | ".hal-c2/vcs.json" names "jj" and ".t3/vcs.json" names "git"                              | Jujutsu  |
      | the file names the system as "vcsKind": "jj" at its top level                            | Jujutsu  |
      | the file names the system as "vcs": { "kind": "jj" } and also as "vcsKind": "git"        | Jujutsu  |
      | the file holds comments and trailing commas around "vcs": { "kind": "jj" }               | Jujutsu  |
      | a folder above "shop" names "jj" and "shop" itself holds no file                         | Jujutsu  |

  # Legacy: apps/server/src/vcs/VcsDriverRegistry.ts (resolve), VcsProvisioningService.ts (resolveRequestedKind)
  @mc @backlog @priority-low
  Scenario Outline: A version control system the MC cannot use is named when it is asked for
    Given <situation>
    When <request>
    Then the request fails with "<message>"

    Examples:
      | situation                                             | request                                  | message                                                 |
      | "shop" is not in any repository                       | a repository action is asked for "shop"  | No supported VCS repository was detected at the folder. |
      | "shop" is a git repository and the project asks for "jj" | a repository action is asked for "shop" | No jj repository was detected at the folder.            |
      | the MC has no driver for "jj"                         | the user initializes "jj" for "notes"    | No jj VCS driver is registered.                         |
      | the system to initialize is left unknown              | the user initializes "notes"             | A concrete VCS driver kind is required for repository provisioning. |

  # Legacy: apps/server/src/vcs/VcsProvisioningService.ts (resolveRequestedKind)
  @mc @priority-high
  Scenario: Initializing without naming a system creates a git repository
    Given the project "notes" is not in a git repository
    When the user initializes "notes" without naming a version control system
    Then "notes" becomes a git repository

  # Legacy: apps/server/src/vcs/VcsDriverRegistry.ts (null detections are not cached)
  @mc @priority-high
  Scenario: A folder that has just become a repository is noticed at once
    Given the project "notes" is not in a git repository
    And status was just read for "notes" and said it is not a repository
    When "notes" is initialized as a git repository
    Then the next status for "notes" reports the repository

  # Legacy: apps/server/src/vcs/VcsProcess.ts (VCS_PROCESS_CONCURRENCY, GITHUB_PROCESS_CONCURRENCY)
  @mc @backlog
  Scenario: Source control commands wait their turn instead of flooding the machine
    Given many threads ask for git work at the same moment
    Then no more than 8 version control commands run at once
    And no more than 4 GitHub CLI commands run at once

  # Legacy: apps/server/src/vcs/VcsProcess.ts (isTransientGitExit, CHECKPOINT_CAPTURE_OPERATION)
  @mc @priority-high
  Scenario: A checkpoint is not lost to a brief git lock
    Given git reports a lock file or a vanished file while a checkpoint is being captured
    When the capture command is retried
    Then the checkpoint is captured if the second or third attempt succeeds

  @backlog @mc @priority-low
  Scenario: A Jujutsu checkout reports its status
    Given the project "shop" is a Jujutsu repository
    When status is read for "shop"
    Then the status reports the Jujutsu driver with its bookmark and working copy changes

  @mc @priority-high
  Scenario: Reading status never takes the git index lock
    Given the MC keeps the status of "shop" fresh in the background
    When the user runs "git checkout" or "git commit" in "shop" while a status read is under way
    Then the user's git command is not refused for a lock the MC holds
